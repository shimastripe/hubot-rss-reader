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
notifyList = []
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
				robot.logger.debug obj
				newItems.push obj

		feedparser.on 'end', ()->
			oldItems = rssCache[title]
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

		feedparser

	# init rss-reader
	robot.brain.once 'loaded', () =>
		notifyList = robot.brain.get('RSS_LIST') or []
		rssCache = robot.brain.get('RSS_CACHE') or {}

		for item in notifyList
			fp = fetchRSS item.url
			feedList.push fp

	robot.hear /register (.*)$/, (res) ->
		robot.logger.debug "Call /feed-register command."

		notifyList = robot.brain.get('RSS_LIST') or []
		args = res.match[1].split ' '
		url = args[0]
		createdAt = moment()

		type = 'default'
		if args.length > 1
			type = args[1]

		obj = {}
		if notifyList.length is 0
			obj = {index: 1, url: url, type: type, updatedAt: createdAt.format()}
		else
			obj = {index: (notifyList.length+1), url: url, type: type, lastUpdated: createdAt.format()}

		robot.logger.debug obj
		notifyList.push obj

		res.send "Register: " + url
		robot.brain.set 'RSS_LIST', notifyList

		watchItem = setInterval ()->
			fetchRSS(url)
		, 1000 * 5

	robot.hear /remove (.*)$/, (res) ->
		notifyList = robot.brain.get('RSS_LIST') or []
		newList = notifyList.filter (element, index, array)->
			element.index != Number(res.match[1])
		robot.brain.set 'RSS_LIST', newList

	robot.hear /list$/, (res) ->
		notifyList = robot.brain.get('RSS_LIST') or []
		console.log notifyList
