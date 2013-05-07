{Adapter,TextMessage} = require 'hubot'
flowdock              = require 'flowdock'

class Flowdock extends Adapter
  send: (params, strings...) ->
    user = @userFromParams(params)
    for str in strings
      if str.length > 8096
        str = "** End of Message Truncated **\n" + str
        str = str[0...8096]
      if user.flow
        @bot.message user.flow, str
      else if user.id
        @bot.privateMessage user.id, str

  reply: (params, strings...) ->
    user = @userFromParams(params)
    strings.forEach (str) =>
      @send params, "@#{user.name}: #{str}"

  userFromParams: (params) ->
    # hubot < 2.4.2: params = user
    # hubot >= 2.4.2: params = {user: user, ...}
    if params.user then params.user else params

  userFromId: (id, data) ->
    # hubot < 2.5.0: @userForId
    # hubot >=2.5.0: @robot.brain.userForId
    @robot.brain?.userForId?(id, data) || @userForId(id, data)

  connect: ->
    ids = (flow.id for flow in @flows)
    @stream = @bot.stream(ids, active: 'idle', user: 1)
    @stream.on 'message', (message) =>
      return unless message.event == 'message'
      author =
        id: message.user
        name: @userFromId(message.user).name
        flow: message.flow
      return if @robot.name.toLowerCase() == author.name.toLowerCase()

      # Reformat leading @mention name to be like "name: message" which is
      # what hubot expects. Add bot name with private messages if not already given.
      botPrefix = "#{@robot.name}: "
      regex = new RegExp("^@#{@robot.name}(,|\\b)", "i")
      hubotMsg = message.content.replace(regex, botPrefix)
      if !message.flow && !hubotMsg.match(new RegExp("^#{@robot.name}", "i"))
        hubotMsg = botPrefix + hubotMsg
      @receive new TextMessage(author, hubotMsg)

  run: ->
    @login_email    = process.env.HUBOT_FLOWDOCK_LOGIN_EMAIL
    @login_password = process.env.HUBOT_FLOWDOCK_LOGIN_PASSWORD
    unless @login_email && @login_password
      console.error "ERROR: No credentials in environment variables HUBOT_FLOWDOCK_LOGIN_EMAIL and HUBOT_FLOWDOCK_LOGIN_PASSWORD"
      @emit "error", "No credentials"

    @bot = new flowdock.Session(@login_email, @login_password)
    @bot.flows (flows) =>
      @flows = flows
      for flow in flows
        for user in flow.users
          data =
            id: user.id
            name: user.nick
          @userFromId user.id, data
      @connect()

    @bot

    @emit 'connected'

exports.use = (robot) ->
  new Flowdock robot
