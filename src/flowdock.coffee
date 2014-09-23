{Adapter,TextMessage} = require 'hubot'
flowdock              = require 'flowdock'

class Flowdock extends Adapter
  constructor: ->
    @flowsByParametrizedNames = {}
    super

  send: (envelope, strings...) ->
    for str, i in strings
      if str.length > 8096
        str = "** End of Message Truncated **\n" + str
        str = str[0...8096]
        strings[i] = str
    flow = envelope.metadata.room
    thread_id = envelope.metadata.thread_id
    message_id = envelope.metadata.message_id
    user = envelope.user
    forceNewMessage = envelope.newMessage == true
    if user?
      for str in strings
        if flow
          if thread_id and not forceNewMessage
            # respond to a thread
            @bot.threadMessage flow, thread_id, str
          else if message_id and not forceNewMessage
            # respond via comment if we have a parent message
            @bot.comment flow, message_id, str
          else
            @bot.message flow, str
        else if user.id
          @bot.privateMessage user.id, str
    else if envelope.room
      flow = @flowFromParams(envelope)
      return new Error("Flow not found") if !flow
      for str in strings
        @bot.message flow.id, str

  reply: (params, strings...) ->
    user = @userFromParams(params)
    strings.forEach (str) =>
      @send params, "@#{user.name}: #{str}"

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
    @stream = @bot.stream(ids, active: 'idle', user: 1)
    @stream.on 'message', (message) =>
      if message.event == 'user-edit'
        @changeUserNick(message.content.user.id, message.content.user.nick)
      return unless message.event in ['message', 'comment']

      author = @userFromId(message.user)
      return if @robot.name.toLowerCase() == author.name.toLowerCase()

      messageId = if message.event == 'message'
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
      regex = new RegExp("^@#{@robot.name}(,|\\b)", "i")
      hubotMsg = msg.replace(regex, botPrefix)
      if !message.flow && !hubotMsg.match(new RegExp("^#{@robot.name}", "i"))
        hubotMsg = botPrefix + hubotMsg

      author.room = message.flow # Many scripts expect author.room to be available
      author.flow = message.flow # For backward compatibility

      metadata =
        room: message.flow
      metadata['message_id'] = messageId if messageId
      metadata['thread_id'] = message.thread_id if message.thread_id

      messageObj = new TextMessage(author, hubotMsg, message.id, metadata)
      # Support metadata even if hubot does not currently do that
      messageObj.metadata = metadata if !messageObj.metadata?

      @receive messageObj

  run: ->
    @login_email    = process.env.HUBOT_FLOWDOCK_LOGIN_EMAIL
    @login_password = process.env.HUBOT_FLOWDOCK_LOGIN_PASSWORD
    unless @login_email && @login_password
      console.error "ERROR: No credentials in environment variables HUBOT_FLOWDOCK_LOGIN_EMAIL and HUBOT_FLOWDOCK_LOGIN_PASSWORD"
      @emit "error", "No credentials"

    @bot = new flowdock.Session(@login_email, @login_password)
    @bot.on "error", (e) =>
      if e == 401
        console.error "Could not authenticate, please check your credentials"
      else
        console.error "Unexpected error in creating Flowdock session: #{e}"
      @emit e

    @bot.flows (flows, response) =>
      @flows = flows
      for flow in flows
        for user in flow.users
          data =
            id: user.id
            name: user.nick
          savedUser = @userFromId user.id, data
          if (savedUser.name != data.name)
            @changeUserNick(savedUser.id, data.name)
      @connect()

    @bot

    @emit 'connected'

exports.use = (robot) ->
  new Flowdock robot
