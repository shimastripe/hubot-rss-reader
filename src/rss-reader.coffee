# Description
#   RSS reader for lab slack
#
# Configuration:
#   LIST_OF_ENV_VARS_TO_SET
#
# Commands:
#   hubot hello - <what the respond trigger does>
#   orly - <what the hear trigger does>
#
# Notes:
#   <optional notes required for the script>
#
# Author:
#   Go Takagi <takagi@shimastripe.com>

# util
_ = require 'lodash'
moment = require 'moment'

# RSS
RssFeedEmitter = require 'rss-feed-emitter'
feeder = new RssFeedEmitter()
FeedParser = require 'feedparser'
request = require 'request'
validUrl = require 'valid-url'
RSSList = {}

# scraping lib
puppeteer = require 'puppeteer'
url = require 'url'
querystring = require 'querystring'
pukiwikiCache = {}

parsePukiwikiDate = (str)->
	# str = 27 Jul 2017 13:27:07 JST
	# JST is invalid. should be +0900
	a = str.split(', ')[1]
	b = a.split ' '

	switch b[4]
		when "JST" then b[4] = "+0900"

	moment b.join ' '

parseDiffData = (items)->
	_.map items, (value, key)->
		line = ""
		type = 0
		switch
			when _.startsWith value, '<span class="diff_added">'
				line = value.split('<span class="diff_added">')[1].split('</span>')[0]
				type = 1
			when _.startsWith value, '<span class="diff_removed">'
				line = value.split('<span class="diff_removed">')[1].split('</span>')[0]
				type = -1
			else
				line = value
		{id:key+1, type:type, line:line}

module.exports = (robot)->
	getRSSList = ()->
		robot.brain.get('RSS_LIST') or {}

	setRSSList = (rss)->
		robot.brain.set 'RSS_LIST', rss

	getCache = ()->
		robot.brain.get('CACHEITEMS') or {}

	setCache = (rss)->
		robot.brain.set 'CACHEITEMS', rss

	getDiffCache = ()->
		robot.brain.get('CACHEDIFFITEMS') or {}

	setDiffCache = (rss)->
		robot.brain.set 'CACHEDIFFITEMS', rss

	fetchRSS = (opt, feedURL, channelId)->
		robot.logger.debug "Fetch RSS feed: " + feedURL
		newItems = []

		req = request feedURL
		feedparser = new FeedParser

		req.on 'error', (error)->
			console.error error
		req.on 'response', (res)->
			if res.statusCode isnt 200
				@emit 'error', new Error('Bad status code')
			else
				@pipe feedparser

		feedparser.on 'error', (error)->
			# always handle errors
			console.error error

		feedparser.on 'readable', ()->
			while item = @read()
				d = moment item.pubdate
				if !d.isValid()
					d = parsePukiwikiDate(item['rss:pubdate']['#'])

				obj =
					title:item.title
					description:item.description
					summary:item.summary
					author:item.author
					link:item.link
					pubdate:d.format()
					feedName: item.meta.title

				newItems.push obj

		feedparser.on 'end', ()->
			cache = getCache()
			oldItems = cache[channelId][feedURL]
			console.log 111
			console.log oldItems
			console.log 222

			if _.isEmpty oldItems
				cache[channelId][feedURL] = newItems
				setCache cache

				if opt.type is "pukiwikidiff"
					_.forEach newItems, (value, key)->
						itemLink = url.parse value.link
						sourceURL = url.parse feedURL
						itemLink.auth = sourceURL.auth

						cacheEditData url.format(itemLink)
						.then (editData)-> console.log editData
				return

			notifyItems = _.differenceWith newItems, oldItems, _.isEqual

			switch opt.type
				when "pukiwikidiff"
					_.forEach notifyItems, (value, key)->
						text = value.description
						if _.isNull text
							text = ''

						authorName = value.author_name
						if _.isNull authorName
							authorName = ''

						itemLink = url.parse value.link
						sourceURL = url.parse feedURL
						itemLink.auth = sourceURL.auth

						att =
							fallback: 'feed:' + value.feedName + ", " + value.title
							color: '#66cdaa'
							author_name: authorName
							title: value.title
							title_link: value.link
							footer: value.feedName

						robot.messageRoom channelId, {attachments: [att]}

						scrapeDiff url.format(itemLink)
						.then (diffItems)->
							text = _.reduce diffItems, (result, value, key)->
								switch value.type
									when 1
										result += '+ ' + value.line + '\n'
									when -1
										result += '- ' + value.line + '\n'
									else
										result += '  ' + value.line + '\n'
								result
							, ''

							options =
								title: value.title
								filename: value.feedName
								content: text
								filetype: 'diff'
								channels: channelId

							robot.adapter.client.web.files.upload value.feedName, options
				else
					_.forEach notifyItems, (value, key)->
						text = value.summary
						if _.isNull text
							text = ''

						authorName = value.author
						if _.isNull authorName
							authorName = ''

						attachment =
							fallback: 'feed:' + value.feedName + ", " + value.title
							color: '#439FE0'
							author_name: authorName
							title: value.title
							title_link: value.link
							text: text
							footer: value.feedName
							mrkdwn_in: ['text']

						robot.messageRoom channelId, {attachments: [attachment]}

			cache[channelId][feedURL] = newItems
			setCache cache

	scrapeDiff = (urlStr)->
		urlObj = url.parse urlStr
		target = _.find urlObj.query.split('&'), (o)->
			!o.includes '='
		target = querystring.parse "page=" + target

		diffUrlObj =
			protocol: urlObj.protocol,
			hostname: urlObj.hostname,
			auth: urlObj.auth,
			pathname: urlObj.pathname,
			query: {cmd: 'diff', page: target.page}

		puppeteer.launch({args: ['--no-sandbox', '--disable-setuid-sandbox']})
		.then (browser)->
			browser.newPage()
			.then (page)->
				page.on 'console', console.log
				page.goto url.format(diffUrlObj)
				.then ->
					page.$eval 'pre', (el) => el.innerHTML
					.then (dom)->
						parseDiffData dom.split('\n')
			.then (parseDom) ->
				browser.close()
				parseDom
			.catch (err)->
				console.error err
				browser.close()

	cacheEditData = (urlStr)->
		urlObj = url.parse urlStr
		target = _.find urlObj.query.split('&'), (o)->
			!o.includes '='
		target = querystring.parse "page=" + target

		diffUrlObj =
			protocol: urlObj.protocol,
			hostname: urlObj.hostname,
			auth: urlObj.auth,
			pathname: urlObj.pathname,
			query: {cmd: 'edit', page: target.page}

		_.forEach notifyItems, (value, key)->
			puppeteer.launch({args: ['--no-sandbox', '--disable-setuid-sandbox']})
			.then (browser)->
				browser.newPage()
				.then (page)->
					page.on 'console', console.log
					page.goto url.format(diffUrlObj)
					.then ->
						page.$eval 'textarea[name=msg]', (el) => el.innerHTML
						.then (dom)->
							dom.split('\n')
				.then (parseDom) ->
					browser.close()
					parseDom
				.catch (err)->
					console.error err
					browser.close()

	# init rss-reader
	robot.brain.once 'save', () =>
		RSSList = getRSSList()

		setInterval ()->
			_.forEach RSSList, (v, k)->
				_.forEach v, (opt, key)->
					fetchRSS opt, key, k
		, 1000 * 20

	robot.router.post '/slash/feed/register', (req, res) ->
		return unless req.body.token == process.env.HUBOT_SLACK_TOKEN_VERIFY
		if req.body.challenge?
			# Verify
			challenge = req.body.challenge
			return res.json challenge: challenge

		robot.logger.debug "Slash /feed-register."

		args = req.body.text.split ' '
		feedURL = args[0]
		createdAt = moment()
		type = 'default'
		if args.length > 1
			type = args[1]

		if !validUrl.isUri feedURL
			res.send "Invalid URL!"
			return

		obj = {id: Number(createdAt.format('x')), type: type}
		RSSList = getRSSList()
		cache = getCache()

		if !_.has RSSList, req.body.channel_id
			RSSList[req.body.channel_id] = {}
		if !_.has cache, req.body.channel_id
			cache[req.body.channel_id] = {}

		RSSList[req.body.channel_id][feedURL] = obj
		cache[req.body.channel_id][feedURL] = []
		setRSSList RSSList
		setCache cache

		res.send "Register: " + feedURL

	robot.router.post '/slash/feed/remove', (req, res) ->
		return unless req.body.token == process.env.HUBOT_SLACK_TOKEN_VERIFY
		if req.body.challenge?
			# Verify
			challenge = req.body.challenge
			return res.json challenge: challenge

		robot.logger.debug "Slash /feed-remove."
		id = Number(req.body.text)
		RSSList = getRSSList()
		cache = getCache()
		hasFlag = false

		_.forEach RSSList[req.body.channel_id], (value, key)->
			if value.id is id
				hasFlag = true
				RSSList[req.body.channel_id] = _.omit RSSList[req.body.channel_id], [key]
				setRSSList RSSList
				cache[req.body.channel_id] = _.omit cache[req.body.channel_id], [key]
				setCache cache

				res.send "Delete: " + key
				false
			true

		if !hasFlag
			res.send "This id does not exist."

	robot.router.post '/slash/feed/list', (req, res) ->
		return unless req.body.token == process.env.HUBOT_SLACK_TOKEN_VERIFY
		if req.body.challenge?
			# Verify
			challenge = req.body.challenge
			return res.json challenge: challenge

		robot.logger.debug "Slash /feed-list."
		RSSList = getRSSList()

		str = _.reduce RSSList[req.body.channel_id], (result, value, key)->
			result + "id: " + value.id + "\nurl: " + key + "\ntype: " + value.type + "\n\n"
		, ''

		res.send str
