scribeLog = require('../pasha_modules/scribe_log').scribeLog
https = require('https')
http = require('http')
constant = require('../pasha_modules/constant').constant
State = require('../pasha_modules/model').State
nodemailer = require "nodemailer"
moment = require('moment')

ack = ['roger', 'roger that', 'affirmative', 'ack', 'consider it done', 'done', 'aye captain']

downloadUsers = (token, setUsersCallback)->
    scribeLog "downloading users"
    try
        options = {
            hostname: "api.hipchat.com"
            port: 443
            path: "/v1/users/list?format=json&auth_token=#{token}"
            method: "GET"
        }
        https.get options, (res) ->
            data = ''
            res.on 'data', (chunk) ->
                data += chunk.toString()
            res.on 'end', () ->
                users = JSON.parse(data)["users"]
                setUsersCallback(users)
                scribeLog "downloaded #{users.length} users"
    catch error
        scribeLog "ERROR " + error
        setUsersCallback([])

getUser = (who, myName, users) ->
    name = who.toLowerCase().replace(/@/g, "").replace(/\s+$/g, "")
    if (name == "me")
        if not myName?
            scribeLog "cannot find 'me' because myName is not set"
            return null
        name = myName.toLowerCase().replace(/@/g, "").replace(/\s+$/g, "")
    matchedUsers = []
    for user in users
        if (user.name.toLowerCase() == name or user.mention_name.toLowerCase() == name)
            scribeLog "user found: #{user.name}"
            return user
        if (user.name.toLowerCase().indexOf(name) != -1 or user.mention_name.toLowerCase().indexOf(name) != -1)
            matchedUsers.push user
    if (matchedUsers.length == 1)
        user = matchedUsers[0]
        scribeLog "user found: #{user.name}"
        return user
    scribeLog "no such user: #{name}"
    return null

getOrInitState = (adapter) ->
    pashaStateStr = adapter.brain.get(constant.pashaStateKey)
    if (not pashaStateStr? or pashaStateStr.length == 0)
        adapter.brain.set(constant.pashaStateKey, JSON.stringify(new State()))
        pashaStateStr = adapter.brain.get(constant.pashaStateKey)
        scribeLog "state was not found, successfully initialized it"
    pashaState = JSON.parse(pashaStateStr)
    return pashaState

updateTopic = (token, updateTopicCallback, msg, newTopic) ->
    try
        options = {
            hostname: "api.hipchat.com"
            port: 443
            path: "/v1/rooms/list?format=json&auth_token=#{token}"
            method: "GET"
        }
        https.get options, (res) ->
            data = ''
            res.on 'data', (chunk) ->
                data += chunk.toString()
            res.on 'end', () ->
                rooms = JSON.parse(data)["rooms"]
                for room in rooms
                    if room.name == msg.message.room
                        updateTopicCallback(msg, room.topic, newTopic)
    catch error
        scribeLog "ERROR " + error

postToHipchat = (channel, message) ->
    try
        postData = "room_id=#{channel}&from=Pasha&message=#{message}&notify=1"
        httpsPostOptions = {
            hostname: "api.hipchat.com"
            port: 443
            path: "/v1/rooms/message?format=json&auth_token=#{constant.hipchatApiToken}"
            method: "POST"
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
                'Content-Length': Buffer.byteLength(postData)
            }
        }
        req = https.request httpsPostOptions, (res) ->
            data = ''
            res.on 'data', (chunk) ->
                data += chunk.toString()
            res.on 'end', () ->
                scribeLog "hipchat response: #{data}"
        req.write(postData)
        req.end()
        scribeLog "request sent"
    catch error
        scribeLog "ERROR " + error

generatePrio1Description = (prio1) ->
    return """
        Outage '#{prio1.title}'
        #{generatePrio1Status(prio1)}
    """

generatePrio1Status = (prio1) ->
    detectTime = moment.unix(prio1.time.start)
    confirmTime = moment.unix(prio1.time.confirm)
    return """
        Latest status: #{prio1.status}
        Communication is handled by #{prio1.role.communication}
        Leader is #{prio1.role.leader}
        Detected by #{prio1.role.starter} at #{detectTime.calendar()} - #{detectTime.fromNow()}
        Confirmed by #{prio1.role.confirmer} at #{confirmTime.calendar()} - #{detectTime.fromNow()}
    """

sendStatusEmail = (prio1) ->
    try
        sendEmail(prio1.title, generatePrio1Status(prio1))
    catch error
        scribeLog "ERROR sendStatusEmail #{error}"

sendConfirmEmail = (prio1) ->
    try
        sendEmail(prio1.title, generatePrio1Description(prio1))
    catch error
        scribeLog "ERROR sendConfirmEmail #{error}"

sendEmail = (subject, text) ->
    try
        transporter = nodemailer.createTransport()
        transporter.sendMail({
            from: constant.pashaEmailAddress
            to: constant.outageEmailAddress
            subject: subject
            text: text
        })
        scribeLog "email sent to #{constant.outageEmailAddress} with subject: #{subject}"
    catch error
        scribeLog "ERROR " + error

pagerdutyAlert = (description) ->
    try
        for serviceKey in constant.pagerdutyServiceKeys
            postData = JSON.stringify({
                service_key: serviceKey
                event_type: "trigger"
                description: description
            })
            httpsPostOptions = {
                hostname: "events.pagerduty.com"
                port: 443
                path: "/generic/2010-04-15/create_event.json"
                method: "POST"
                headers: {
                    'Content-Type': 'application/json',
                    'Content-Length': Buffer.byteLength(postData)
                }
            }
            req = https.request httpsPostOptions, (res) ->
                data = ''
                res.on 'data', (chunk) ->
                    data += chunk.toString()
                res.on 'end', () ->
                    scribeLog "pagerduty response: #{data}"
            req.write(postData)
            req.end()
            scribeLog "pagerduty alert triggered: #{description}"
    catch error
        scribeLog "ERROR " + error


startNag = (adapter, msg) ->
    state = getOrInitState(adapter)
    prio1 = state.prio1
    naggerCallbackId = null
    nagger = () ->
        if (not getOrInitState(adapter).prio1?)
            if (not naggerCallbackId?)
                scribeLog "nagger callback shouldn't be called but it was"
                return
            clearInterval naggerCallbackId
            scribeLog "stopped nagging #{prio1.title}"
            return
        try
            nagTarget = if prio1.role.comm then prio1.role.comm else prio1.role.starter
            msg.send "@#{getUser(nagTarget, null, state.users).mention_name}, please use '#{constant.botName} status <some status update>' regularly, the last status update for the current outage was at #{moment.unix(prio1.time.lastStatus).fromNow()}"
        catch error
            scribeLog "ERROR nagger #{error}"
    naggerCallbackId = setInterval(nagger, 10 * 60 * 1000)

hasValue = (str) ->
    str? and str

module.exports = {
    getUser: getUser
    downloadUsers : downloadUsers 
    getOrInitState: getOrInitState
    ack: ack
    updateTopic: updateTopic
    postToHipchat: postToHipchat
    sendEmail: sendEmail
    sendConfirmEmail: sendConfirmEmail
    sendStatusEmail: sendStatusEmail
    pagerdutyAlert: pagerdutyAlert
    startNag: startNag
    hasValue: hasValue
}
