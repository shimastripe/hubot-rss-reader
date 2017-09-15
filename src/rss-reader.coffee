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
RSSList = []
CacheItems = {}

parsePukiwikiDate = (str)->
	# str = 27 Jul 2017 13:27:07 JST
	# JST is invalid. should be +0900
	a = str.split(', ')[1]
	b = a.split ' '

	switch b[4]
		when "JST" then b[4] = "+0900"

	moment b.join ' '

module.exports = (robot)->
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
			oldItems = CacheItems[title]
			# console.log oldItems
			CacheItems[title] = newItems
			robot.brain.set 'CACHEITEMS', CacheItems
			console.log newItems

		req = request url
		req.on 'error', (error) ->
			console.error error
		req.on 'response', (res)->
			if res.statusCode isnt 200
				@emit 'error', new Error('Bad status code')
			else
				@pipe feedparser

	getRSSList = ()->
		robot.brain.get('RSS_LIST') or {}

	setRSSList = (rss)->
		robot.brain.set 'RSS_LIST', rss

	# init rss-reader
	robot.brain.once 'loaded', () =>
		RSSList = getRSSList()
		CacheItems = robot.brain.get('CACHEITEMS') or {}

		setInterval ()->
			_.forEach RSSList, (item, key)->
				fetchRSS key
		, 1000 * 5

	robot.hear /register (.*)$/, (res) ->
		robot.logger.debug "Call /feed-register command."

		args = res.match[1].split ' '
		url = args[0]
		createdAt = moment()
		type = 'default'
		if args.length > 1
			type = args[1]

		obj = {id: Number(createdAt.format('x')), type: type}
		RSSList = getRSSList()
		RSSList[url] = obj

		res.send "Register: " + url
		setRSSList RSSList

	robot.hear /remove (.*)$/, (res) ->
		id = Number(res.match[1])
		RSSList = getRSSList()
		hasFlag = false

		_.forEach RSSList, (value, key)->
			if value.id is id
				hasFlag = true
				RSSList = _.omit RSSList, [key]
				setRSSList RSSList
				res.send "Delete: " + key
				false
			true

		if !hasFlag
			res.send "This id does not exist."

	robot.hear /list$/, (res) ->
		RSSList = getRSSList()

		str = _.reduce RSSList, (result, value, key)->
			result + "id: " + value.id + "\nurl: " + key + "\ntype: " + value.type + "\n\n"
		, ''

		res.send str
