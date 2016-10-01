Promise = require 'bluebird'
dockerUtils = require './docker-utils'
{ docker } = dockerUtils
express = require 'express'
fs = Promise.promisifyAll require 'fs'
{ resinApi } = require './request'
knex = require './db'
_ = require 'lodash'
deviceRegister = require 'resin-register-device'
randomHexString = require './lib/random-hex-string'
utils = require './utils'
device = require './device'
bodyParser = require 'body-parser'
request = Promise.promisifyAll require 'request'
appConfig = require './config'
PUBNUB = require 'pubnub'
execAsync = Promise.promisify(require('child_process').exec)
url = require 'url'

pubnub = PUBNUB.init(appConfig.pubnub)

getAssetsPath = (image) ->
	docker.imageRootDir(image)
	.then (rootDir) ->
		return rootDir + '/assets'

isDefined = _.negate(_.isUndefined)

exports.router = router = express.Router()
router.use(bodyParser())

parseDeviceFields = (device) ->
	device.id = parseInt(device.deviceId)
	device.appId = parseInt(device.appId)
	device.config = JSON.parse(device.config ? '{}')
	device.environment = JSON.parse(device.environment ? '{}')
	device.targetConfig = JSON.parse(device.targetConfig ? '{}')
	device.targetEnvironment = JSON.parse(device.targetEnvironment ? '{}')
	return device


router.get '/v1/devices', (req, res) ->
	knex('dependentDevice').select()
	.map(parseDeviceFields)
	.then (devices) ->
		res.json(devices)
	.catch (err) ->
		res.status(503).send(err?.message or err or 'Unknown error')

router.post '/v1/devices', (req, res) ->
	Promise.join(
		utils.getConfig('apiKey')
		utils.getConfig('userId')
		device.getID()
		deviceRegister.generateUUID()
		randomHexString.generate()
		(apiKey, userId, deviceId, uuid, logsChannel) ->
			d =
				user: userId
				application: req.body.appId
				uuid: uuid
				device_type: 'edge'
				device: deviceId
				registered_at: Math.floor(Date.now() / 1000)
				logs_channel: logsChannel
				status: 'Provisioned'
			resinApi.post
				resource: 'device'
				body: d
				customOptions:
					apikey: apiKey
			.then (dev) ->
				deviceForDB = {
					uuid: uuid
					appId: d.application
					device_type: d.device_type
					deviceId: dev.id
					name: dev.name
					status: d.status
					logs_channel: d.logs_channel
				}
				knex('dependentDevice').insert(deviceForDB)
				.then ->
					res.status(201).send(dev)
	)
	.catch (err) ->
		console.error("Error on #{req.method} #{url.parse(req.url).pathname}", err, err.stack)
		res.status(503).send(err?.message or err or 'Unknown error')

router.get '/v1/devices/:uuid', (req, res) ->
	uuid = req.params.uuid
	knex('dependentDevice').select().where({ uuid })
	.then ([ device ]) ->
		return res.status(404).send('Device not found') if !device?
		res.json(parseDeviceFields(device))
	.catch (err) ->
		console.error("Error on #{req.method} #{url.parse(req.url).pathname}", err, err.stack)
		res.status(503).send(err?.message or err or 'Unknown error')

router.post '/v1/devices/:uuid/logs', (req, res) ->
	uuid = req.params.uuid
	m = {
		message: req.body.message
		timestamp: req.body.timestamp or Date.now()
	}
	m.isSystem = req.body.isSystem if req.body.isSystem?

	knex('dependentDevice').select().where({ uuid })
	.then ([ device ]) ->
		return res.status(404).send('Device not found') if !device?
		pubnub.publish({ channel: "device-#{device.logs_channel}-logs", message: m })
		res.status(202).send('OK')
	.catch (err) ->
		console.error("Error on #{req.method} #{url.parse(req.url).pathname}", err, err.stack)
		res.status(503).send(err?.message or err or 'Unknown error')

validStringOrUndefined = (s) ->
	_.isUndefined(s) or !_.isEmpty(s)
validObjectOrUndefined = (o) ->
	_.isUndefined(o) or _.isObject(o)

router.put '/v1/devices/:uuid', (req, res) ->
	uuid = req.params.uuid
	{ status, is_online, commit, environment, config } = req.body
	if isDefined(is_online) and !_.isBoolean(is_online)
		res.status(400).send('is_online must be a boolean')
		return
	if !validStringOrUndefined(status)
		res.status(400).send('status must be a non-empty string')
		return
	if !validStringOrUndefined(commit)
		res.status(400).send('commit must be a non-empty string')
		return
	if !validObjectOrUndefined(environment)
		res.status(400).send('environment must be an object')
		return
	if !validObjectOrUndefined(config)
		res.status(400).send('config must be an object')
		return
	environment = JSON.stringify(environment) if isDefined(environment)
	config = JSON.stringify(config) if isDefined(config)

	Promise.join(
		utils.getConfig('apiKey')
		knex('dependentDevice').select().where({ uuid })
		(apiKey, [ device ]) ->
			throw new Error('apikey not found') if !apiKey?
			return res.status(404).send('Device not found') if !device?
			resinApi.patch
				resource: 'device'
				id: device.deviceId
				body: _.pick({ status, is_online, commit }, isDefined)
				customOptions:
					apikey: apiKey
			.then ->
				fieldsToUpdate = _.pick({ status, is_online, commit, config, environment }, isDefined)
				knex('dependentDevice').update(fieldsToUpdate).where({ uuid })
			.then ->
				res.json(parseDeviceFields(device))
	)
	.catch (err) ->
		console.error("Error on #{req.method} #{url.parse(req.url).pathname}", err, err.stack)
		res.status(503).send(err?.message or err or 'Unknown error')

tarPath = ({ commit }) ->
	return '/tmp/' + commit + '.tar'

router.get '/v1/dependent-apps/:appId/assets/:commit', (req, res) ->
	knex('dependentApp').select().where(_.pick(req.params, 'appId', 'commit'))
	.then ([ app ]) ->
		return res.status(404).send('Not found') if !app
		dest = tarPath(app)
		getAssetsPath(app.imageId)
		.then (path) ->
			getTarArchive(path, dest)
		.then ->
			res.sendFile(dest)
	.catch (err) ->
		console.error("Error on #{req.method} #{url.parse(req.url).pathname}", err, err.stack)
		res.status(503).send(err?.message or err or 'Unknown error')

router.get '/v1/dependent-apps', (req, res) ->
	knex('dependentApp').select()
	.map (app) ->
		return {
			id: parseInt(app.appId)
			commit: app.commit
			device_type: 'edge'
			name: app.name
			config: JSON.parse(app.config ? '{}')
		}
	.then (apps) ->
		res.json(apps)
	.catch (err) ->
		console.error("Error on #{req.method} #{url.parse(req.url).pathname}", err, err.stack)
		res.status(503).send(err?.message or err or 'Unknown error')

getTarArchive = (path, destination) ->
	fs.lstatAsync(path)
	.then ->
		execAsync("tar -cvf '#{destination}' *", cwd: path)

# TODO: deduplicate code from compareForUpdate in application.coffee
exports.fetchAndSetTargetsForDependentApps = (state, fetchFn, apiKey) ->
	knex('dependentApp').select()
	.then (localDependentApps) ->
		# Compare to see which to fetch, and which to delete
		remoteApps = _.mapValues state.apps, (app, appId) ->
			conf = app.config ? {}
			return {
				appId: appId
				parentAppId: app.parentApp
				imageId: app.image
				commit: app.commit
				config: JSON.stringify(conf)
				name: app.name
			}
		localApps = _.indexBy(localDependentApps, 'appId')

		toBeDownloaded = _.filter remoteApps, (app, appId) ->
			return app.commit? and app.imageId? and !_.any(localApps, imageId: app.imageId)
		toBeRemoved = _.filter localApps, (app, appId) ->
			return app.commit? and !_.any(remoteApps, imageId: app.imageId)
		Promise.map toBeDownloaded, (app) ->
			fetchFn(app, false)
		.then ->
			Promise.map toBeRemoved, (app) ->
				fs.unlinkAsync(tarPath(app))
				.then ->
					docker.getImage(app.imageId).removeAsync()
				.catch (err) ->
					console.error('Could not remove image/artifacts for dependent app', err, err.stack)
		.then ->
			Promise.props(
				_.mapValues remoteApps, (app, appId) ->
					knex('dependentApp').update(app).where({ appId })
					.then (n) ->
						knex('dependentApp').insert(app) if n == 0
			)
		.then ->
			Promise.all _.map state.devices, (device, uuid) ->
				# Only consider one app per dependent device for now
				appId = _(device.apps).keys().first()
				targetCommit = state.apps[appId].commit
				targetEnvironment = JSON.stringify(device.apps[appId].environment ? {})
				targetConfig = JSON.stringify(device.apps[appId].config ? {})
				knex('dependentDevice').update({ targetEnvironment, targetConfig, targetCommit, name: device.name }).where({ uuid })
				.then (n) ->
					return if n != 0
					# If the device is not in the DB it means it was provisioned externally
					# so we need to fetch it.
					resinApi.get
						resource: 'device'
						options:
							filter:
								uuid: uuid
						customOptions:
							apikey: apiKey
					.then ([ dev ]) ->
						deviceForDB = {
							uuid: uuid
							appId: appId
							device_type: dev.device_type
							deviceId: dev.id
							is_online: dev.is_online
							name: dev.name
							status: dev.status
							logs_channel: dev.logs_channel
							targetCommit
							targetConfig
							targetEnvironment
						}
						knex('dependentDevice').insert(deviceForDB)
	.catch (err) ->
		console.error('Error fetching dependent apps', err, err.stack)

sendUpdate = (device, endpoint) ->
	request.putAsync "#{endpoint}#{device.uuid}", {
		json: true
		body:
			appId: device.appId
			commit: device.targetCommit
			environment: JSON.parse(device.targetEnvironment)
			config: JSON.parse(device.targetConfig)
	}
	.spread (response, body) ->
		if response.statusCode != 200
			return console.error("Error updating device #{device.uuid}: #{response.statusCode} #{body}")

getHookEndpoint = (appId) ->
	knex('dependentApp').select('parentAppId').where({ appId })
	.then ([ { parentAppId } ]) ->
		knex('app').select().where({ appId: parentAppId })
	.then ([ parentApp ]) ->
		conf = JSON.parse(parentApp.config)
		dockerUtils.getImageEnv(parentApp.imageId)
		.then (imageEnv) ->
			return imageEnv.RESIN_DEPENDENT_DEVICES_HOOK_ADDRESS ?
				conf.RESIN_DEPENDENT_DEVICES_HOOK_ADDRESS ?
				"#{appConfig.proxyvisorHookReceiver}/v1/devices/"

exports.sendUpdates = ->
	endpoints = {}
	knex('dependentDevice').select()
	.map (device) ->
		currentState = _.pick(device, 'commit', 'environment', 'config')
		targetState = {
			commit: device.targetCommit
			environment: device.targetEnvironment
			config: device.targetConfig
		}
		if device.targetCommit? and !_.isEqual(targetState, currentState)
			endpoints[device.appId] ?= getHookEndpoint(device.appId)
			endpoints[device.appId]
			.then (endpoint) ->
				sendUpdate(device, endpoint)