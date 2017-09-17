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

filterDiffData = (items)->
	outputIndex = _
		.chain items
		.filter (item)->
			item.type != 0
		.flatMap (n)->
			[n.id-1, n.id, n.id+1]
		.uniq()
		.value()

	blankItem = _
		.chain outputIndex
		.map (n)->
			if _.includes outputIndex, n+1
				return {id: -1}
			return {id: n+1, type: 0, line: "=========="}
		.filter (n)-> n.id > 0
		.initial()
		.value()

	_.chain items
	.filter (n)->
		_.includes outputIndex, n.id
	.union blankItem
	.orderBy ['id']
	.value()

module.exports = (robot)->
	getRSSList = ()->
		robot.brain.get('RSS_LIST') or {}

	setRSSList = (rss)->
		robot.brain.set 'RSS_LIST', rss

	getCache = ()->
		robot.brain.get('CACHEITEMS') or {}

	setCache = (rss)->
		robot.brain.set 'CACHEITEMS', rss

	fetchRSS = (opt, url, channelId)->
		robot.logger.debug "Fetch RSS feed: " + url
		newItems = []

		req = request url
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

				obj = {title:item.title, description:item.description, link:item.link, pubdate:d.format(), feedName: item.meta.title}
				newItems.push obj

		feedparser.on 'end', ()->
			cache = getCache()
			oldItems = cache[channelId][url]

			if _.isEmpty oldItems
				cache[channelId][url] = newItems
				setCache cache
				return

			notifyItems = _.differenceWith newItems, oldItems, _.isEqual

			switch opt.type
				when "pukiwikidiff"
					console.log "pukiwikidiff"

				else
					_.forEach notifyItems, (value, key)->
						if _.isNull value.description
							value.description = ''
						attachment = {
							title: value.title
							author_name: value.feedName
							fallback: 'feed:' + value.feedName + ", " + value.title
							text: value.description
							color: '#439FE0'
							mrkdwn_in: ['text']
						}

			cache[channelId][url] = newItems
			setCache cache

	scrapeDiff = (urlStr)->
		urlObj = url.parse urlStr
		target = _.find urlObj.query.split('&'), (o)->
			!o.includes '='
		target = querystring.parse "page=" + target

		diffUrlObj = {
			protocol: urlObj.protocol,
			hostname: urlObj.hostname,
			auth: urlObj.auth,
			pathname: urlObj.pathname,
			query: {cmd: 'diff', page: target.page}
		}

		puppeteer.launch()
		.then (browser)->
			browser.newPage()
			.then (page)->
				page.on 'console', console.log
				page.goto url.format(diffUrlObj)
				.then ->
					page.$eval 'pre', (el) => el.innerHTML
					.then (dom)->
						parseDom = parseDiffData dom.split('\n')
						parseDom = filterDiffData parseDom

						console.log parseDom
			.then ->
				browser.close()
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
		, 1000 * 5

	robot.router.post '/slash/feed/register', (req, res) ->
		return unless req.body.token == process.env.HUBOT_SLACK_TOKEN_VERIFY
		if req.body.challenge?
			# Verify
			challenge = req.body.challenge
			return res.json challenge: challenge

		robot.logger.debug "Slash /feed-register."

		args = req.body.text.split ' '
		url = args[0]
		createdAt = moment()
		type = 'default'
		if args.length > 1
			type = args[1]

		if !validUrl.isUri url
			res.send "Invalid URL!"
			return

		obj = {id: Number(createdAt.format('x')), type: type}
		RSSList = getRSSList()

		if !_.has RSSList, req.body.channel_id
			RSSList[req.body.channel_id] = {}
		RSSList[req.body.channel_id][url] = obj

		res.send "Register: " + url
		setRSSList RSSList

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


# DEBUG
	robot.hear /register (.*)$/, (res)->
		robot.logger.debug "Slash /feed-register."

		args = res.match[1].split ' '
		url = args[0]
		createdAt = moment()
		type = 'default'
		if args.length > 1
			type = args[1]

		if !validUrl.isUri url
			res.send "Invalid URL!"
			return

		obj = {id: Number(createdAt.format('x')), type: type}
		RSSList = getRSSList()
		RSSList[url] = obj

		res.send "Register: " + url
		setRSSList RSSList

	robot.hear /reset (.*)$/, (res)->
		robot.brain.set res.match[1], {}
