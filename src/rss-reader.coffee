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
RSSList = {}

parsePukiwikiDate = (str)->
	# str = 27 Jul 2017 13:27:07 JST
	# JST is invalid. should be +0900
	a = str.split(', ')[1]
	b = a.split ' '

	switch b[4]
		when "JST" then b[4] = "+0900"

	moment b.join ' '

module.exports = (robot)->
	fetchRSS = (opt, url)->
		robot.logger.debug "Fetch RSS feed: " + url
		newItems = []

		req = request url
		feedparser = new FeedParser

		req.on 'error', (error) ->
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

				obj = {title:item.title, description:item.description, link:item.link, pubdate:d.format()}
				newItems.push obj

		feedparser.on 'end', ()->
			cache = getCache()
			oldItems = cache[url]

			if _.isEmpty oldItems
				cache[url] = newItems
				setCache cache
				return

			notifyItems = _.differenceWith newItems, oldItems, _.isEqual

			switch opt.type
				when "pukiwikidiff"
					console.log "pukiwikidiff"
				else
					_.forEach notifyItems, (value, key)->
						console.log value

			cache[url] = newItems
			setCache cache

	getRSSList = ()->
		robot.brain.get('RSS_LIST') or {}

	setRSSList = (rss)->
		robot.brain.set 'RSS_LIST', rss

	getCache = ()->
		robot.brain.get('CACHEITEMS') or {}

	setCache = (rss)->
		robot.brain.set 'CACHEITEMS', rss

	# init rss-reader
	robot.brain.once 'loaded', () =>
		RSSList = getRSSList()

		setInterval ()->
			_.forEach RSSList, (opt, key)->
				fetchRSS opt, key
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
		cache = getCache()
		hasFlag = false

		_.forEach RSSList, (value, key)->
			if value.id is id
				hasFlag = true
				RSSList = _.omit RSSList, [key]
				setRSSList RSSList
				cache = _.omit cache, [key]
				setCache cache

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
