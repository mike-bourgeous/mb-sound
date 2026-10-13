module MB
  module Sound
    module Help
      # The coverage guard (maintainer, 2026-10-13): every public console
      # command (a method MB::Sound extends itself with) appears in a topic,
      # on the sheet, or here with a reason, so a new command without help
      # fails spec/lib/mb/sound/help_spec.rb.  Library plumbing is exempted
      # by module where a whole module is plumbing, else by name.  Setters
      # (`master_gain=`) and aliases count through their method.
      module Coverage
        # Whole modules that are not console commands.
        EXEMPT_MODULES = {
          'MB::Sound::FFTMethods' => 'FFT helpers for library code and analysis scripts (help :analysis lists the console ones)',
          'MB::Sound::FFTMethods::PocketfftMethods' => 'FFT wrappers used by FFTMethods',
          'MB::Sound::GainMethods' => 'array normalization helpers for library code',
          'MB::Sound::WindowMethods' => 'windowed (overlap-add) processing for library code and analysis scripts',
          'MB::Sound::ScriptingMethods' => 'bin/ script helpers (design/notes/scripts.md), not console commands',
          'MB::Sound::LiveMethods' => 'live-mode switches for library code (live_error), set by bin/sound.rb',
        }.freeze

        # Single console methods that are plumbing, with the reason.
        EXEMPT = {
          plotter: 'the shared plotter object behind plot',
          keeping_random_state: 'library code that must not move the random state',
          live_midi_latency: 'the latency live MIDI input adds (read by MIDI sources)',
          drawn_seed: 'a mark graph documents write around seeds (seed: drawn_seed(N)), read by their loader',
        }.freeze

        module_function

        # Console commands (non-alias, non-setter) and where each is
        # covered: a topic name, :sheet, or :exempt.
        def report(index = Help.index)
          # A listed alias covers its method (`vis` covers `visualize`)
          originals = index.console_methods.select(&:alias?).to_h { |e| [e.name, e.original] }
          covered = TOPICS.values.reverse.flat_map { |t| t.names.flat_map { |n| [[n, t.name], [originals[n], t.name]] } }.reject { |n, _| n.nil? }.to_h
          sheet = Sheet::SHEET.values.flatten.flat_map(&:call_names)
          sheet += sheet.filter_map { |n| originals[n] }
          index.console_methods.reject { |e| e.alias? || e.name.end_with?('=') }.to_h { |e|
            where =
              if covered.key?(e.name) then covered[e.name]
              elsif sheet.include?(e.name) then :sheet
              elsif EXEMPT_MODULES.key?(e.owner.name) || EXEMPT.key?(e.name) then :exempt
              end
            [e.name, where]
          }
        end

        # Console commands without help or an exemption (the guard spec
        # expects none).
        def uncovered(index = Help.index) = report(index).select { |_, w| w.nil? }.keys
      end
    end
  end
end
