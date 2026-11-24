require 'json'
# Examples that leave Pry's process-wide config changed (fixes-19).  The
# console's setup (Help.install_pry!, UI.install_pry!) wraps Pry.config.print
# in Help::PagePrinter, renames Pry commands named like console commands,
# and adds hooks; help_spec's show-doc example ran Help.install_pry! on the
# real config and never put the printer back, so every later example that
# printed through Pry had its result cut at Help::RESULT_LINES (30) lines:
# tiles_spec's 80-line pager example failed after it, an earlier merge
# train having recorded that as "a pager wait_for timeout under load".
#
# What is compared, before and after each example while Pry is loaded:
# Pry.config.print (the same object), Pry.config.commands (the same set,
# no command gone, no pry-* rename or mb-sound command added; a plugin the
# example loads, as pry-byebug, may add its own), and Pry.config.hooks
# (the same object, the same hook names per event).  An example that loads Pry itself is compared
# with what a fresh Pry has: no PagePrinter, no pry-* renames, no mb_sound_*
# hooks.
#
# MB_SOUND_PRY_CHECK:
# - unset or "fail" (default): the example fails, naming what changed; the
#   guard puts the printer and hooks back (renamed commands it can only
#   name), so one leak fails one example;
# - "report": such examples are listed after the run instead;
# - "off": no check.
#
# Stub Pry.config.commands and .hooks (`allow(config).to
# receive(:commands)`) and put Pry.config.print back in an `ensure`, as
# help_spec's install_pry! examples do.
module PryConfigGuard
  MODES = %w[report fail off].freeze

  @records = []

  class << self
    attr_reader :records

    def mode
      m = ENV.fetch('MB_SOUND_PRY_CHECK', 'fail')
      raise ArgumentError, "MB_SOUND_PRY_CHECK is one of #{MODES.join(', ')} (got #{m.inspect})" unless MODES.include?(m)
      m
    end

    # The parts of Pry's config the console's setup changes, or nil while
    # Pry isn't loaded.
    def snapshot
      return nil unless defined?(::Pry) && ::Pry.respond_to?(:config)
      c = ::Pry.config
      {
        print: c.print,
        commands: c.commands,
        command_names: command_names(c.commands),
        hooks: c.hooks,
        hook_names: hook_names(c.hooks),
      }
    end

    def command_names(set)
      set.respond_to?(:keys) ? set.keys.map(&:to_s).sort : set.to_hash.keys.map(&:to_s).sort
    end

    def hook_names(hooks)
      # (Pry::Hooks#hooks is protected: event => [[name, callable], ...],
    # an event read once keeping an empty list)
      hooks.instance_variable_get(:@hooks).filter_map { |ev, list| [ev.to_s, list.map { |name, _| name.to_s }] unless list.empty? }.to_h
    end

    # What differs between +before+ and +after+ (snapshots), as text, or
    # nil.
    def changed(before, after)
      return nil if after.nil?
      out = []
      if before.nil?
        # (Pry was loaded during the example: compare with a fresh Pry)
        out << 'Pry.config.print is a Help::PagePrinter' if page_printer?(after[:print])
        renamed = after[:command_names].grep(/\Apry-/)
        out << "Pry commands renamed (#{renamed.first(4).join(', ')})" unless renamed.empty?
        ours = after[:hook_names].flat_map { |ev, names| names.grep(/\Amb_sound/).map { |n| "#{ev}:#{n}" } }
        out << "hooks added (#{ours.join(', ')})" unless ours.empty?
      else
        out << "Pry.config.print replaced (#{after[:print].class})" unless after[:print].equal?(before[:print])
        if !after[:commands].equal?(before[:commands])
          out << 'Pry.config.commands replaced'
        else
          # (a plugin loaded by the example, pry-byebug, adds its commands
          # to Pry's own set once a process: allowed; the console's setup
          # removes and renames commands and adds mb-sound's)
          added = (after[:command_names] - before[:command_names]).select { |n| n.start_with?('pry-') || mb_command?(after[:commands], n) }
          gone = before[:command_names] - after[:command_names]
          out << "Pry commands changed (+#{added.first(4).join(', ')} -#{gone.first(4).join(', ')})" unless added.empty? && gone.empty?
        end
        if !after[:hooks].equal?(before[:hooks])
          out << 'Pry.config.hooks replaced'
        elsif after[:hook_names] != before[:hook_names]
          out << "Pry hooks changed (#{hook_diff(before[:hook_names], after[:hook_names])})"
        end
      end
      out.empty? ? nil : out.join('; ')
    end

    def mb_command?(set, name)
      c = set.find_command(name)
      c.respond_to?(:description) && c.description.to_s.start_with?('mb-sound')
    rescue StandardError
      false
    end

    def page_printer?(print)
      defined?(MB::Sound::Help::PagePrinter) && print.is_a?(MB::Sound::Help::PagePrinter)
    end

    def hook_diff(a, b)
      (a.keys | b.keys).filter_map { |ev|
        added = (b[ev] || []) - (a[ev] || [])
        gone = (a[ev] || []) - (b[ev] || [])
        next if added.empty? && gone.empty?
        "#{ev}: +#{added.join(',')} -#{gone.join(',')}"
      }.join('; ')
    end

    # Puts back what can be put back: the printer, and the hooks the
    # example added (or the hooks object it replaced).
    def restore(before)
      c = ::Pry.config
      if before
        c.print = before[:print] unless c.print.equal?(before[:print])
        c.hooks = before[:hooks] unless c.hooks.equal?(before[:hooks])
        before_names = before[:hook_names]
      else
        c.print = Pry::ColorPrinter.method(:default) if page_printer?(c.print)
        before_names = {}
      end
      hook_names(c.hooks).each do |ev, names|
        (names - (before_names[ev] || [])).each { |n| c.hooks.delete_hook(ev, n) }
      end
    rescue StandardError
      nil
    end
  end
end

unless PryConfigGuard.mode == 'off'
  RSpec.configure do |config|
    config.around(:each) do |example|
      before = PryConfigGuard.snapshot
      example.run
      what = PryConfigGuard.changed(before, PryConfigGuard.snapshot)
      next unless what

      PryConfigGuard.restore(before)
      if PryConfigGuard.mode == 'fail'
        raise "the example left Pry's config changed (#{what}): stub Pry.config.commands/hooks and put Pry.config.print back " \
              'in an ensure (spec/support/pry_config_guard.rb)'
      end
      PryConfigGuard.records << { 'example' => example.location, 'changed' => what }
    end

    config.after(:suite) do
      list = PryConfigGuard.records
      unless list.empty?
        puts "\nExamples leaving Pry's config changed (#{list.length}; MB_SOUND_PRY_CHECK=fail fails them):"
        list.first(20).each { |r| puts "  #{r['example']}  #{r['changed']}" }
      end
    end
  end
end
