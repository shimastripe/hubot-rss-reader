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

FeedSub = require 'feedsub'

module.exports = (robot) ->
	reader = new FeedSub 'http://rss.cnn.com/rss/cnn_latest.rss', {
		interval: 0.1 # check feed every 10 minutes
	}

	reader.on 'item', (item) ->
		console.log('Got item!');
		console.dir(item);

	reader.start()
