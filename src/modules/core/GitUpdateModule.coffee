module.exports = (Module) ->
	Q = require 'q'
	fs = require 'fs'
	https = require 'https'
	_ = require 'lodash'
	path = require 'path'
	child_process = require 'child_process'
	
	class GitUpdateModule extends Module
		shortName: "GitUpdate"
	
		helpText:
			default: "Update my internals, woooo~"
			'auto-update': "Change how often I try to update myself."
	
		usage:
			default: "update"
			'auto-update': "auto-update [minutes|never]"
	
		constructor: (moduleManager) ->
			super(moduleManager)
	
			accessToken = @getApiKey 'github'
	
			if not accessToken?
				console.log "No GitHub access token specified in config files; I will not be able to update from GitHub."
				return
	
			@defaultGitHubParams =
				hostname: "api.github.com"
				headers:
					"User-Agent": "kellyirc_kurea"
	
			[@owner, @repo, @head] = ["kellyirc", "kurea", "master"]

			updateInterval = (@settings.get "updateIntervalMinutes") ? 10

			if _.isNumber updateInterval
				@autoUpdateId = setInterval =>
					@checkUpdate accessToken
				, updateInterval * 60 * 1000
				
				console.log "Updating every #{updateInterval} minutes"

			else
				console.log "Auto-update disabled"
	
			@addRoute "update", "core.update.command", (origin, route) =>
				@checkUpdate accessToken, origin
	
			@addRoute "auto-update :min", "core.update.interval", (origin, route) =>
				timeMin = route.params.min
	
				if timeMin is "never"
					clearInterval @autoUpdateId if @autoUpdateId?
					@autoUpdateId = null
	
					@reply origin, "Disabled auto-update checking. Re-enable by specifying how often I should check for updates in minutes!"
					@settings.set "updateIntervalMinutes", "never"

				else if not isNaN Number(timeMin)
					timeMin = Number(timeMin)
					clearInterval @autoUpdateId if @autoUpdateId?
					@autoUpdateId = setInterval =>
						@checkUpdate accessToken
					, timeMin * 60 * 1000

					@reply origin, "I will now check for updates every #{timeMin} minutes!"
					@settings.set "updateIntervalMinutes", timeMin

				else
					@reply origin, "Sorry, I don't really understand what that's supposed to mean! Try specifying a number or 'never' instead!"
	
		destroy: =>
			console.log "Killing old update interval"
			clearInterval @autoUpdateId if @autoUpdateId?
	
			super()
	
		getCurrentCommit: (callback) =>
			Q.nfcall fs.readFile, ".git/HEAD",
				encoding: "utf-8"
	
			.then (filedata) =>
				[match, headPath] = /ref: (.+)\n/.exec(filedata)
	
				Q.nfcall fs.readFile, ".git/#{headPath}",
					encoding: "utf-8"
	
			.then (filedata) =>
				hash = _.trim( filedata )
				callback null, hash
	
			.fail (err) =>
				callback err, null
	
		checkUpdate: (accessToken, origin) ->
			@getCurrentCommit (err, hash) =>
				if err?
					console.error "There was a problem!"
					console.error err.stack
					return
	
				compareOptions =
					auth: "#{accessToken}:x-oauth-basic"
					path: "/repos/#{@owner}/#{@repo}/compare/#{hash}...#{@head}"
	
				#console.log "Checking for update..."
				@reply origin, "Checking for updates..." if origin?
	
				req = https.request _.extend(compareOptions, @defaultGitHubParams), (res) =>
					chunks = []
					res.on 'data', (data) =>
						chunks.push data
						
					.on 'end', =>
						data = JSON.parse Buffer.concat(chunks).toString()
	
						if data.commits.length > 0
							#console.log "Update available!"
							@update data, origin
						else
							#console.log "No need to update..."
							@reply origin, "No new commits available; no update is performed." if origin?
	
				req.on 'error', (e) -> console.error e.stack
				req.end()
	
		update: (data, origin) ->
			[meh..., last] = data.commits
			headHash = last.sha
			console.log "Updating to #{headHash}"
	
			filenames = (file.filename for file in data.files)
	
			Q.fcall =>
				console.log "Running 'git pull'..."
				@reply origin, "Pulling new commits..." if origin?
	
				deferred = Q.defer()
	
				gitPull = child_process.exec "git pull", (err, stdout, stderr) ->
					if err? then deferred.reject err
	
				gitPull.stdout.on 'data', (chunk) -> console.log "#{chunk}"
				gitPull.stderr.on 'data', (chunk) -> console.error "#{chunk}"
				gitPull.on 'close', (code, signal) -> deferred.resolve code, signal

				gitSubmodules = child_process.exec "git submodule foreach git pull", (err, stdout, stderr) ->
				if err? then deferred.reject err

				gitSubmodules.stdout.on 'data', (chunk) -> console.log "#{chunk}"
				gitSubmodules.stderr.on 'data', (chunk) -> console.error "#{chunk}"
				gitSubmodules.on 'close', (code, signal) -> deferred.resolve code, signal
	
				deferred.promise
	
			.then =>
				if "package.json" in filenames
					console.log "'npm install'ing potential new deps"
	
					deferred = Q.defer()
					gitPull = child_process.exec "npm install", (err, stdout, stderr) ->
						if err? then deferred.reject err
	
					gitPull.stdout.on 'data', (chunk) -> console.log "#{chunk}"
					gitPull.stderr.on 'data', (chunk) -> console.error "#{chunk}"
					gitPull.on 'close', (code, signal) -> deferred.resolve code, signal
	
					deferred.promise
	
			.then =>
				console.log "Updated all files to #{headHash}; now exiting"
				@reply origin, "Updated all files to latest commit; restarting in about 5 seconds" if origin?
	
				setTimeout (-> process.exit 0), 5000
	
			.fail (err) =>
				console.log "Error:", err
				@reply origin, "There was a problem while updating: #{err.message}" if origin?
	
	
	GitUpdateModule
