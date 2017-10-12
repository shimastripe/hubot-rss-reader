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

// scraping lib
const puppeteer = require('puppeteer');
const url = require('url');
const querystring = require('querystring');

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

let parseDiffData = (items) => {
    return _.map(items, (value, key) => {
        let line = "";
        let type = 0;

        if (_.startsWith(value, '<span class="diff_added">')) {
            line = value.split('<span class="diff_added">')[1].split('</span>')[0];
            type = 1;
        } else if (_.startsWith(value, '<span class="diff_removed">')) {
            line = value.split('<span class="diff_removed">')[1].split('</span>')[0];
            type = -1;
        } else {
            line = value;
        }

        return { id: key + 1, type: type, line: line };
    });
};

module.exports = robot => {
    let getRSSList = () => {
        return robot.brain.get('RSS_LIST') || {};
    };

    let setRSSList = rss => {
        return robot.brain.set('RSS_LIST', rss);
    };

    let getCache = () => {
        return robot.brain.get('CACHEITEMS') || {};
    };

    let setCache = rss => {
        return robot.brain.set('CACHEITEMS', rss);
    };

    let fetchRSS = (opt, feedURL, channelId) => {
        robot.logger.debug("Fetch RSS feed: " + feedURL);
        let newItems = [];

        let req = request(feedURL);
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

                // d = d.add("h", 9)

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
            let cache = getCache();
            let oldItems = cache[channelId][feedURL];

            if (_.isEmpty(oldItems)) {
                cache[channelId][feedURL] = newItems;
                setCache(cache);
                return;
            }

            let notifyItems = _.differenceWith(newItems, oldItems, _.isEqual);

            switch (opt.type) {
                case "pukiwikidiff":
                    _.forEach(notifyItems, async (value, key) => {
                        let text = value.description;
                        if (_.isNull(text)) {
                            text = '';
                        }

                        let authorName = value.author_name
                        if (_.isNull(authorName)) {
                            authorName = '';
                        }

                        let itemLink = url.parse(value.link);
                        let sourceURL = url.parse(feedURL);
                        itemLink.auth = sourceURL.auth;

                        let att = {
                            fallback: 'feed:' + value.feedName + ", " + value.title,
                            color: '#66cdaa',
                            author_name: authorName,
                            title: value.title,
                            title_link: value.link,
                            footer: value.feedName
                        };

                        let diffItems = await scrapeDiff(url.format(itemLink));
                        text = _.reduce(diffItems, (result, value, key) => {
                            switch (value.type) {
                                case 1:
                                    result += '+ ' + value.line + '\n';
                                    break;
                                case -1:
                                    result += '- ' + value.line + '\n';
                                    break;
                                default:
                                    result += '  ' + value.line + '\n';
                                    break;
                            }
                            return result;
                        }), '';

                        let options = {
                            title: value.title,
                            filename: value.feedName,
                            content: text,
                            filetype: 'diff',
                            channels: channelId
                        };

                        robot.messageRoom(channelId, { attachments: [att] });
                        robot.adapter.client.web.files.upload(value.feedName, options);
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

                        robot.messageRoom(channelId, { attachments: [attachment] });
                    });
                    break;
            }

            cache[channelId][feedURL] = newItems;
            setCache(cache);
        });
    };

    let scrapeDiff = async (urlStr) => {
        let urlObj = url.parse(urlStr);
        let target = _.find(urlObj.query.split('&'), (o) => {
            return !o.includes('=');
        });
        target = querystring.parse("page=" + target);

        let diffUrlObj = {
            protocol: urlObj.protocol,
            hostname: urlObj.hostname,
            auth: urlObj.auth,
            pathname: urlObj.pathname,
            query: { cmd: 'diff', page: target.page }
        }

        return puppeteer.launch({ args: ['--no-sandbox', '--disable-setuid-sandbox'] }).then(async browser => {
            const page = await browser.newPage();
            await page.on('console', console.log);
            await page.goto(url.format(diffUrlObj));
            const dom = await page.$eval('pre', (el) => el.innerHTML);
            await browser.close();
            return parseDiffData(dom.split('\n'));
        });
    };

    // init rss-reader
    robot.brain.once('save', () => {
        let RSSList = getRSSList();

        setInterval(() => {
            _.forEach(RSSList, (v, k) => {
                _.forEach(v, (opt, key) => {
                    fetchRSS(opt, key, k);
                });
            });
        }, 1000 * 10);
    });
};