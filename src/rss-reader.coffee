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

RssFeedEmitter = require 'rss-feed-emitter'
feeder = new RssFeedEmitter()
readerList = []

feeder.on 'new-item', (item)->
  console.log(item)

module.exports = (robot) ->
  # init rss-reader
  robot.brain.once 'loaded', () =>
    notifyList = robot.brain.get('RSS_LIST') or []
    notifyList.foreach (val,index,ar)->
      feeder.add {
        url: val.url,
        refresh: 2000
      }

  robot.hear /register (.*)$/, (res) ->
    robot.logger.debug "Call /feed-register command."
    notifyList = robot.brain.get('RSS_LIST') or []
    url = res.match[1]

    if notifyList.length is 0
      notifyList.push {index:1, url:url, type:'default'}
    else
      notifyList.push {index:(notifyList.length+1), url:url, type:'default'}

    robot.brain.set 'RSS_LIST', notifyList

    res.send "Register: " + url
    feeder.add {
      url: url,
      refresh: 2000
    }

  robot.hear /remove (.*)$/, (res) ->
    notifyList = robot.brain.get('RSS_LIST') or []
    newList = notifyList.filter (element, index, array)->
      element.index != Number(res.match[1])
    robot.brain.set 'RSS_LIST', newList

  robot.hear /list$/, (res) ->
    notifyList = robot.brain.get('RSS_LIST') or []
    console.log notifyList
