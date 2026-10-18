# Fails any example that leaves a terminal UI screen up or the process's
# stdin, stdout, or stderr reopened elsewhere (ux-r4-panes, 2026-10-18): a
# leftover tiled screen adopts fds 0/1/2 and swallows later output, so
# RSpec's output, warnings (warning_guard_spec failed on the Mac when they
# never reached the real stderr), and failure texts landed in its REPL
# pane.  The guard cleans up (stops the screens, puts the fds back) before
# failing, so one leak fails one example, not the rest of the run.
module UIScreenGuard
  STDS = { stdin: STDIN, stdout: STDOUT, stderr: STDERR }.freeze

  # What each fd was when the suite started ([dev, ino] and a dup to
  # restore it from).
  ORIGINAL = STDS.transform_values { |io| [io.stat.then { |st| [st.dev, st.ino] }, io.dup] }.freeze

  def self.problems
    list = []
    ui = MB::Sound::UI
    t = ui.tiles
    list << "a tiled screen is still #{t.hidden? ? 'hidden' : 'up'} (UI.tiles #{t.layout_name.inspect})" if t && (t.active? || t.hidden?)
    list << "a band is still up (UI.band #{ui.band.layout.name.inspect})" if ui.band&.active?
    STDS.each do |name, io|
      id = (io.stat.then { |st| [st.dev, st.ino] } rescue nil)
      list << "#{name} was left reopened elsewhere (a screen adopted it and never gave it back)" unless id == ORIGINAL[name][0]
    end
    list
  end

  def self.clean_up
    ui = MB::Sound::UI
    (ui.tiles&.stop rescue nil)
    (ui.band&.stop rescue nil)
    ui.instance_variable_set(:@tiles, nil)
    ui.instance_variable_set(:@band, nil)
    STDS.each do |name, io|
      id = (io.stat.then { |st| [st.dev, st.ino] } rescue nil)
      io.reopen(ORIGINAL[name][1]) unless id == ORIGINAL[name][0]
    end
  end
end

RSpec.configure do |config|
  config.after(:each) do |example|
    problems = UIScreenGuard.problems
    unless problems.empty?
      UIScreenGuard.clean_up
      raise "#{example.location} left the terminal UI behind: #{problems.join('; ')} (stop screens in an after/ensure; see spec/support/ui_screen_guard.rb)"
    end
  end
end
