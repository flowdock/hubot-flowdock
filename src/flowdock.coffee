{Adapter,TextMessage} = require 'hubot'
flowdock              = require 'flowdock'

class Flowdock extends Adapter

  send: (envelope, strings...) ->
    return if strings.length == 0
    self = @
    str = strings.shift()
    if str.length > 8096
      str = "** End of Message Truncated **\n" + str
      str = str[0...8096]
    metadata = envelope.metadata || envelope.message.metadata
    flow = metadata.room
    thread_id = metadata.thread_id
    message_id = metadata.message_id
    user = envelope.user
    forceNewMessage = envelope.newMessage == true
    sendRest = ->
      self.send(envelope, strings...)
    if user?
      if flow?
        if thread_id and not forceNewMessage
          # respond to a thread
          @bot.threadMessage flow, thread_id, str, [], sendRest
        else if message_id and not forceNewMessage
          # respond via comment if we have a parent message
          @bot.comment flow, message_id, str, [], sendRest
        else
          @bot.message flow, str, [], sendRest
      else if user.id
        # If replying as private message, strip the preceding user tag
        str = str.replace(new RegExp("^@#{user.name}: ", "i"), '')
        @bot.privateMessage user.id, str, [], sendRest
    else if flow
      @bot.message flow, str, [], sendRest

  reply: (envelope, strings...) ->
    user = @userFromParams(envelope)
    @send envelope, strings.map((str) -> "@#{user.name}: #{str}")...

  userFromParams: (params) ->
    # hubot < 2.4.2: params = user
    # hubot >= 2.4.2: params = {user: user, ...}
    if params.user then params.user else params

  flowFromParams: (params) ->
    return flow for flow in @flows when params.room == flow.id

  userFromId: (id, data) ->
    # hubot < 2.5.0: @userForId
    # hubot >=2.5.0: @robot.brain.userForId
    @robot.brain?.userForId?(id, data) || @userForId(id, data)

  changeUserNick: (id, newNick) ->
    if id of @robot.brain.data.users
      @robot.brain.data.users[id].name = newNick

  connect: ->
    ids = (flow.id for flow in @flows)
    @robot.logger.info('Flowdock: connecting')
    @stream = @bot.stream(ids, active: 'idle', user: 1)
    @stream.on 'connected', => @robot.logger.info('Flowdock: connected and streaming')
    @stream.on 'clientError', (error) => @robot.logger.error('Flowdock: client error:', error)
    @stream.on 'disconnected', => @robot.logger.info('Flowdock: disconnected')
    @stream.on 'reconnecting', => @robot.logger.info('Flowdock: reconnecting')
    @stream.on 'message', (message) =>
      if message.event == 'user-edit'
        @changeUserNick(message.content.user.id, message.content.user.nick)
      return unless message.event in ['message', 'comment']
      return if String(@bot.userId) == String(message.user)

      @robot.logger.debug 'Received message', message

      author = @userFromId(message.user)

      thread_id = message.thread_id
      messageId = if thread_id?
        undefined
      else if message.event == 'message'
        message.id
      else
        # For comments the parent message id is embedded in an 'influx' tag
        if message.tags
          influxTag = do ->
            for tag in message.tags
              return tag if /^influx:/.test tag
          (influxTag.split ':', 2)[1] if influxTag

      msg = if message.event == 'comment' then message.content.text else message.content

      # Reformat leading @mention name to be like "name: message" which is
      # what hubot expects. Add bot name with private messages if not already given.
      botPrefix = "#{@robot.name}: "
      regex = new RegExp("^@#{@bot.userName}(,|\\b)", "i")
      hubotMsg = msg.replace(regex, botPrefix)
      if !message.flow && !hubotMsg.match(new RegExp("^#{@robot.name}", "i"))
        hubotMsg = botPrefix + hubotMsg

      author.room = message.flow # Many scripts expect author.room to be available
      author.flow = message.flow # For backward compatibility

      metadata =
        room: message.flow
      metadata['thread_id'] = thread_id if thread_id?
      metadata['message_id'] = messageId if messageId?

      messageObj = new TextMessage(author, hubotMsg, message.id, metadata)
      # Support metadata even if hubot does not currently do that
      messageObj.metadata = metadata if !messageObj.metadata?

      @receive messageObj

  run: ->
    @apiToken      = process.env.HUBOT_FLOWDOCK_API_TOKEN
    @loginEmail    = process.env.HUBOT_FLOWDOCK_LOGIN_EMAIL
    @loginPassword = process.env.HUBOT_FLOWDOCK_LOGIN_PASSWORD
    if @apiToken?
      @bot = new flowdock.Session(@apiToken)
    else if @loginEmail? && @loginPassword?
      @bot = new flowdock.Session(@loginEmail, @loginPassword)
    else
      throw new Error("ERROR: No credentials given: Supply either environment variable HUBOT_FLOWDOCK_API_TOKEN or both HUBOT_FLOWDOCK_LOGIN_EMAIL and HUBOT_FLOWDOCK_LOGIN_PASSWORD")

    @bot.on "error", (e) =>
      @robot.logger.error("Unexpected error in Flowdock client: #{e}")
      @emit e

    @bot.flows (err, flows, res) =>
      return if err?
      @bot.userId = res.headers['flowdock-user']
      @flows = flows
      @robot.logger.info("Found #{@flows.length} flows.")
      for flow in flows
        for user in flow.users
          data =
            id: user.id
            name: user.nick
          savedUser = @userFromId user.id, data
          if savedUser.name != data.name
            @changeUserNick(savedUser.id, data.name)
          if String(user.id) == String(@bot.userId)
            @bot.userName = user.nick
      @robot.logger.info("Connecting to Flowdock as user #{@bot.userName} (id #{@bot.userId}).")
      if @robot.name.toLowerCase() != @bot.userName.toLowerCase()
        @robot.logger.warning(
          "You have configured this bot to use the wrong name (#{@robot.name}). Flowdock API says " +
          "my name is #{@bot.userName}. You will run into problems if you don't fix this!")

      @connect()

    @emit 'connected'

exports.use = (robot) ->
  new Flowdock robot
