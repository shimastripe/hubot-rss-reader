'use strict';
// Description
//   RSS reader for lab slack
//
// Configuration:
//   LIST_OF_ENV_VARS_TO_SET
//
// Commands:
//   /feed-list
//   /feed-register <URL>
//   /feed-remove <id>
//
// Author:
//   Go Takagi <takagi@shimastripe.com>

// util
const _ = require('lodash');
const moment = require('moment');

// RSS
const RssFeedEmitter = require('rss-feed-emitter');
const feeder = new RssFeedEmitter()
const FeedParser = require('feedparser');
const request = require('request');
const validUrl = require('valid-url');
let RSSList = {};
let articles = {};
let cache = {};

// scraping lib
const puppeteer = require('puppeteer');
const url = require('url');
const querystring = require('querystring');
const jsdiff = require("diff");

let parsePukiwikiDate = (str) => {
	// str = 27 Jul 2017 13:27:07 JST
	// JST is invalid. should be +0900
	let a = str.split(', ')[1];
	let b = a.split(' ');

	switch (b[4]) {
		case "JST":
			b[4] = "+0900"
			break;

		default:
			break;
	}
	return moment(b.join(' '));
};

let getDiffPageUrlObj = (urlObj) => {
	let target = _.find(urlObj.query.split('&'), (o) => {
		return !o.includes('=');
	});
	target = querystring.parse("page=" + target);

	return {
		protocol: urlObj.protocol,
		hostname: urlObj.hostname,
		auth: urlObj.auth,
		pathname: urlObj.pathname,
		query: {
			cmd: 'edit',
			page: target.page
		}
	};
};

let scrapeOnePage = async(urlStr) => {
	const browser = await puppeteer.launch({
		args: ['--no-sandbox', '--disable-setuid-sandbox']
	});
	const page = await browser.newPage();
	await page.on('console', console.log);
	await page.goto(urlStr);
	const dom = await page.$eval('textarea[name=msg]', (el) => el.innerHTML);
	await browser.close();
	return dom;
};

module.exports = robot => {
	// feed list
	let getRSSList = () => {
		return robot.brain.get('RSS_LIST') || [];
	};

	let setRSSList = rss => {
		return robot.brain.set('RSS_LIST', rss);
	};

	// previous feed item list(check update item)
	let getCache = () => {
		return robot.brain.get('CACHEITEMS') || {};
	};

	let setCache = rss => {
		return robot.brain.set('CACHEITEMS', rss);
	};

	// feed item data
	let getArticle = () => {
		return robot.brain.get('WIKIARTICLE') || {};
	};

	let setArticle = rss => {
		return robot.brain.set('WIKIARTICLE', rss);
	};

	let cacheFirstWikiData = async(urlObjArr, chId) => {
		const browser = await puppeteer.launch({
			args: ['--no-sandbox', '--disable-setuid-sandbox']
		});
		const page = await browser.newPage();
		await page.on('console', console.log);

		_.forEach(urlObjArr, async(value, key) => {
			let diffUrlObj = getDiffPageUrlObj(value);
			await page.goto(url.format(diffUrlObj));
			const dom = await page.$eval('textarea[name=msg]', (el) => el.innerHTML);
			let columnName = _.replace(urlObj.query, "%2F", "_");
			articles[chId][columnName] = dom;
		});

		await browser.close();
		setArticle();
		return;
	}

	let fetchRSS = (feedData) => {
		robot.logger.debug("Fetch RSS feed: " + feedData.link);
		let newItems = [];

		let req = request(feedData.link);
		let feedparser = new FeedParser;

		req.on('error', err => {
			console.error(err);
		});
		req.on('response', res => {
			if (res.statusCode != 200) {
				req.emit('error', new Error('Bad status code'));
			} else {
				req.pipe(feedparser);
			}
		});
		feedparser.on('error', err => {
			// always handle errors
			console.error(err);
		});
		feedparser.on('readable', () => {
			let item;
			while (item = feedparser.read()) {
				let d = moment(item.pubdate);
				if (!d.isValid()) {
					d = parsePukiwikiDate(item['rss:pubdate']['#']);
				}

				let obj = {
					title: item.title,
					description: item.description,
					summary: item.summary,
					author: item.author,
					link: item.link,
					pubdate: d.format(),
					feedName: item.meta.title
				};

				newItems.push(obj);
			}
		});
		feedparser.on('end', () => {
			let oldItems = cache[feedData.link];

			if (_.isEmpty(oldItems)) {
				cache[feedData.link] = newItems;
				setCache(cache);

				// if (feedData.type === "pukiwikidiff") {
				// 	cacheFirstWikiData(_.map(newItems, (item) => {
				// 		return url.parse(item.link);
				// 	}));
				// }
				return;
			}

			let notifyItems = _.differenceWith(newItems, oldItems, _.isEqual);
			// let is10minutesStopFlag = false;
			// _.forEach(notifyItems, (value, key) => {
			// 	let itemTime = moment(value.pubdate).add(5, 'minutes');
			// 	if (itemTime > moment().utcOffset(9) {
			// 		is10minutesStopFlag = true;
			// 	}
			// });

			// if (is10minutesStopFlag) {
			// 	return;
			// }

			switch (feedData.type) {
				case "pukiwikidiff":
					_.forEach(notifyItems, async(value, key) => {
						let text = value.description;
						if (_.isNull(text)) {
							text = '';
						}

						let authorName = value.author_name
						if (_.isNull(authorName)) {
							authorName = '';
						}

						let itemLink = url.parse(value.link);
						let sourceURL = url.parse(feedData.link);
						itemLink.auth = sourceURL.auth;

						let att = {
							fallback: 'feed:' + value.feedName + ", " + value.title,
							color: '#66cdaa',
							author_name: authorName,
							title: value.title,
							title_link: value.link,
							footer: value.feedName
						};

						text = await scrapeWiki(url.format(itemLink), value.title);

						_.forEach(feedData.channelIds, (channelId) => {
							let options = {
								title: value.title,
								filename: value.feedName,
								content: text,
								filetype: 'diff',
								channels: channelId
							};

							robot.messageRoom(channelId, {
								attachments: [att]
							});
							robot.adapter.client.web.files.upload(value.feedName, options);
						});
					});
					break;

				default:
					_.forEach(notifyItems, (value, key) => {
						let text = value.summary;
						if (_.isNull(text)) {
							text = '';
						}

						let authorName = value.author;
						if (_.isNull(authorName)) {
							authorName = '';
						}

						let attachment = {
							fallback: 'feed:' + value.feedName + ", " + value.title,
							color: '#439FE0',
							author_name: authorName,
							title: value.title,
							title_link: value.link,
							text: text,
							footer: value.feedName,
							mrkdwn_in: ['text']
						};

						_.forEach(feedData.channelIds, (channelId) => {
							robot.messageRoom(channelId, {
								attachments: [attachment]
							});
						});
					});
					break;
			}

			cache[feedData.link] = newItems;
			setCache(cache);
		});
	};

	let scrapeWiki = async(urlStr, title) => {
		let urlObj = url.parse(urlStr);
		let diffUrlObj = getDiffPageUrlObj(urlObj);
		let dom = await scrapeOnePage(url.format(diffUrlObj));

		let oldArticle = "";
		let columnName = _.replace(urlObj.query, "%2F", "_");
		if (_.has(articles, columnName)) {
			oldArticle = articles[columnName];
		}

		articles[columnName] = dom;
		setArticle();
		return jsdiff.createPatch(title, oldArticle, dom, "old", "new");
	};

	robot.router.post('/slash/feed/register', (req, res) => {
		// if (req.body.token !== process.env.HUBOT_SLACK_TOKEN_VERIFY) {
		// 	res.send("Verify Error");
		// 	return;
		// }

		// if (req.body.challenge != null) {
		// 	let challenge = req.body.challenge;
		// 	return res.json({
		// 		challenge: challenge
		// 	});
		// }
		robot.logger.debug("/feed-register");
		let channelId = req.body.channel_id;
		let args = req.body.text.split(' ');
		let feedURL = args[0];
		let createdAt = moment().utcOffset(9);
		let type = 'default';
		if (args.length > 1) {
			type = args[1];
		}
		if (!validUrl.isUri(feedURL)) {
			res.send("Invalid URL");
			return;
		}

		let obj = _.find(RSSList, {
			link: feedURL,
			type: type
		});

		if (_.isUndefined(obj)) {
			obj = {
				id: Number(createdAt.format('x')),
				channelIds: [],
				link: feedURL,
				type: type
			};
		}

		if (!_.includes(obj.channelIds, channelId)) {
			obj.channelIds.push(channelId);
		}

		RSSList = _.reject(RSSList, {
			link: feedURL,
			type: type
		});
		RSSList.push(obj);
		setRSSList(RSSList);

		cache[feedURL] = [];
		setCache(cache);
		if (type === "pukiwikidiff") {
			articles = {};
			setArticle();
		}
		return res.send("Register: " + feedURL + "\nID: " + obj.id + "\nType: " + obj.type);
	});

	robot.router.post('/slash/feed/remove', (req, res) => {
		// if (req.body.token !== process.env.HUBOT_SLACK_TOKEN_VERIFY) {
		// 	res.send("Verify Error");
		// 	return;
		// }

		// if (req.body.challenge != null) {
		// 	let challenge = req.body.challenge;
		// 	return res.json({
		// 		challenge: challenge
		// 	});
		// }

		robot.logger.debug("/feed-remove");
		let channelId = req.body.channel_id;
		let id = Number(req.body.text);
		let obj = _.find(RSSList, {
			id: id,
			channelIds: [channelId]
		});

		if (_.isUndefined(obj)) {
			return res.send("This id does not exist.");
		}

		RSSList = _.reject(RSSList, {
			id: id,
			channelIds: [channelId]
		});

		if (obj.channelIds.length > 1) {
			_.pull(obj.channelIds, channelId);
			RSSList.push(obj);
		}
		setRSSList(RSSList);
		cache[obj.link] = [];
		setCache(cache);
		if (type === "pukiwikidiff") {
			articles = {};
			setArticle();
		}
		s
		return res.send("Delete feed: " + id);
	});

	robot.router.post('/slash/feed/list', (req, res) => {
		// if (req.body.token !== process.env.HUBOT_SLACK_TOKEN_VERIFY) {
		// 	res.send("Verify Error");
		// 	return;
		// }

		// if (req.body.challenge != null) {
		// 	let challenge = req.body.challenge;
		// 	return res.json({
		// 		challenge: challenge
		// 	});
		// }

		robot.logger.debug("/feed-list");
		let channelId = req.body.channel_id;
		let str = _.reduce(RSSList, (result, value, key) => {
			if (_.includes(value.channelIds, channelId)) {
				return result + "id: " + value.id + "\nurl: " + value.link + "\ntype: " + value.type + "\n\n";
			}
			return result;
		}, '');

		return res.send(str);
	});

	// init rss-reader
	robot.brain.once('save', () => {
		console.log("OK------------------------")
		RSSList = getRSSList();
		articles = getArticle();
		cache = getCache();

		setInterval(() => {
			_.forEach(RSSList, (v, k) => {
				fetchRSS(v);
			});
		}, 1000 * 10);
	});

	//DEBUG
	robot.hear(/resetrsslist/, (res) => {
		RSSList = [];
		setRSSList(RSSList);
	});

	robot.hear(/checkrsslist/, (res) => {
		console.log(RSSList);
	});

	robot.hear(/resetcache/, (res) => {
		cache = {};
		setCache(cache);
	});

	robot.hear(/checkcache/, (res) => {
		console.log(cache);
	});

	robot.hear(/resetarticles/, (res) => {
		articles = {};
		setArticle(articles);
	});

	robot.hear(/checkarticles/, (res) => {
		console.log(articles);
	});
};
