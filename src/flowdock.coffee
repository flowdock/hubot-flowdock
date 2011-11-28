Robot    = require("hubot").robot()
Adapter  = require("hubot").adapter()
flowdock = require "flowdock"

class Flowdock extends Adapter
  send: (user, strings...) ->
    strings.forEach (str) =>
      @bot.chatMessage(user.flow.subdomain, user.flow.name, str)

  reply: (user, strings...) ->
    strings.forEach (str) =>
      @send user, "#{user.name}: #{str}"

  run: ->
    self = @

    @login_email    = process.env.HUBOT_FLOWDOCK_LOGIN_EMAIL
    @login_password = process.env.HUBOT_FLOWDOCK_LOGIN_PASSWORD
    unless @login_email && @login_password
      console.error "ERROR: No credentials in environment variables HUBOT_FLOWDOCK_LOGIN_EMAIL and HUBOT_FLOWDOCK_LOGIN_PASSWORD"
      @emit "error", "No credentials"

    bot = new flowdock.Session(@login_email, @login_password)
    bot.fetchFlows((flows) =>
      flows.forEach (flow) =>
        bot.fetchUsers(flow.organization.subdomain, flow.slug, (users) =>
          users.forEach (flow_user) =>
            return if flow_user.user.disabled == true
            user =
              id: flow_user.user.id
              name: flow_user.user.nick
            @userForId(user.id, user)
        )
        bot.subscribe(flow.organization.subdomain, flow.slug)
    )

    bot.on "message", (message) =>
      return unless message.event == 'message'
      flow = bot.flows.filter((flow) -> return flow.name == message.flow)[0]
      author =
        name: @userForId(message.user).name
        flow: flow
      return if @name == author.name
      self.receive new Robot.TextMessage(author, message.content)

    @bot = bot

exports.use = (robot) ->
  new Flowdock robot
