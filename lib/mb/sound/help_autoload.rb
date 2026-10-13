module MB
  module Sound
    # Loads console help (MB::Sound::Help, HelpMethods; not part of
    # `require 'mb/sound'`, since its doc index and pages are only needed
    # when asked for) the first time a script calls #help, #now, or
    # #lesson, so `help` works in a plain script too (the jungle persona got
    # a NameError until `require 'mb/sound/help'`, 2026-10-13).  Loading
    # help extends MB::Sound with HelpMethods, whose methods then come
    # before these.
    module HelpAutoload
      %i[help now lesson].each do |name|
        define_method(name) do |*args, **kwargs, &block|
          require_relative 'help'
          raise NotImplementedError, "Loading mb/sound/help didn't define #{name}" if HelpMethods.instance_method(name).owner == HelpAutoload

          HelpMethods.instance_method(name).bind_call(self, *args, **kwargs, &block)
        end
      end
    end
  end
end
