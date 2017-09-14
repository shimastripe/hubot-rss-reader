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

_ = require 'lodash'
RssFeedEmitter = require 'rss-feed-emitter'
feeder = new RssFeedEmitter()
FeedParser = require 'feedparser'
request = require 'request'
moment = require 'moment'
readerList = []
RSSList = []
rssCache = {}

parsePukiwikiDate = (str)->
	# str = 27 Jul 2017 13:27:07 JST
	# JST is invalid. should be +0900
	a = str.split(', ')[1]
	b = a.split ' '

	switch b[4]
		when "JST" then b[4] = "+0900"

	moment b.join ' '

module.exports = (robot) ->
	fetchRSS = (url)->
		robot.logger.debug "Fetch RSS feed: " + url
		feedparser = new FeedParser
		newItems = []
		title = ''

		feedparser.on 'error', (error)->
			# always handle errors
			console.error error

		feedparser.on 'readable', ()->
			meta = @meta; # **NOTE** the "meta" is always available in the context of the feedparser instance
			title = meta.title

			while item = @read()
				d = moment item.pubdate
				if !d.isValid()
					d = parsePukiwikiDate(item['rss:pubdate']['#'])
				obj = {title:item.title, description:item.description, link:item.link, pubdate:d.format()}
				# robot.logger.debug obj
				newItems.push obj

		feedparser.on 'end', ()->
			oldItems = rssCache[title]
			# console.log oldItems
			rssCache[title] = newItems
			robot.brain.set 'RSS_CACHE', rssCache

		req = request url
		req.on 'error', (error) ->
			console.error error
		req.on 'response', (res)->
			if res.statusCode isnt 200
				@emit 'error', new Error('Bad status code')
			else
				@pipe feedparser

	# init rss-reader
	robot.brain.once 'loaded', () =>
		RSSList = robot.brain.get('RSS_LIST') or {}
		rssCache = robot.brain.get('RSS_CACHE') or {}

		_.forEach RSSList, (item, key)->
			watchItem = setInterval ()->
				fetchRSS(item.url)
			, 1000 * 5
			readerList[item.url] = watchItem

	robot.hear /register (.*)$/, (res) ->
		robot.logger.debug "Call /feed-register command."

		args = res.match[1].split ' '
		url = args[0]
		createdAt = moment()

		type = 'default'
		if args.length > 1
			type = args[1]

		obj = {id: Number(createdAt.format('x')), type: type}
		robot.logger.debug obj
		RSSList[url] = obj

		res.send "Register: " + url
		robot.brain.set 'RSS_LIST', RSSList

		watchItem = setInterval ()->
			fetchRSS(url)
		, 1000 * 5

		readerList[url] = watchItem

	robot.hear /remove (.*)$/, (res) ->
		id = Number(res.match[1])
		l = robot.brain.get('RSS_LIST') or {}

		_.forEach l, (value, key)->
			console.log key
			if value.id is id
				# clearInterval readerList[value.key]
				# readerList = _.omit readerList, [key]
				#
				# RSSList = _.omit RSSList, [key]
				# robot.brain.set 'RSS_LIST', RSSList

				res.send "Delete: " + key
			else
				res.send "This id does not exist."

	robot.hear /list$/, (res) ->
		console.log RSSList
