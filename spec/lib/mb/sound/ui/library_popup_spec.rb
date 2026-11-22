require_relative '../../../../support/ui_helpers'

# Find-as-you-type for library heads (omnibus15; maintainer 2026-10-28:
# "Better yet... find-as-you-type"): Library::Finder ranks entries by the
# letters typed anywhere in their names, words, and tags, and
# UI::LibraryPopup lists them under the prompt (a Reline dialog) while the
# word is a head chain.
RSpec.describe(MB::Sound::UI::LibraryPopup, :aggregate_failures) do
  let(:finder) { MB::Sound::Library::Finder.new }

  def chains(text) = finder.candidates(text)&.map(&:chain)

  describe MB::Sound::Library::Finder do
    it 'finds entries anywhere in their names, ranked, with the chain that reaches each' do
      expect(chains('L.inst.ree')).to include('L.inst.dnb_reese', 'L.inst.jungle_reese')
      expect(chains('L.reese')).to eq(%w[L.inst.dnb_reese L.inst.jungle_reese]) # (from the root: any head)
      expect(chains('L.inst.eese')).to include('L.inst.dnb_reese') # (inside a name, not only a prefix)
      expect(chains('L.inst.dnb_r').first).to eq('L.inst.dnb_reese')
      expect(chains('L.fx.reverb.').first(3)).to all(start_with('L.fx.reverb.'))
      expect(chains('L.inst.dnb.')).to include('L.inst.dnb.dnb_reese') # (narrowed by a tag first)
      expect(chains('L.in').first).to eq('L.inst') # (a head)
      expect(finder.candidates('L.inst.ree').first.label).to match(/\A\w+ +instrument/)
    end

    it 'lists nothing outside head chains, for an exact entry, or for a word that does not narrow' do
      expect(chains('x = 1')).to be_nil
      expect(chains('Lx.inst.')).to be_nil
      expect(chains('L.inst.dnb_reese')).to be_nil
      expect(chains('L.fx.reverb.hall.')).to be_nil # (an Entry: its methods are Pry's)
      expect(chains('L.inst.nope.')).to be_nil
      expect(chains('L.inst.zzzz')).to be_nil
    end
  end

  describe 'at the prompt (a real Pry and Reline on the screen\'s pty)' do
    before { described_class.install }
    after do
      @tiles&.stop
      @term&.close
      ::Reline.add_dialog_proc(:mb_library, nil)
    end

    # True once the list for +word+ is drawn and Reline holds its keys
    # (one-shot bindings, added after each draw): keys typed after this
    # reach the list, as keys typed apart do (a key decoded in the same
    # read as the one before it would come before the bindings).
    def listed?(word)
      st = ::Reline.dialog_proc(:mb_library).context
      keys = ::Reline.send(:core).config.instance_variable_get(:@oneshot_key_bindings).instance_variable_get(:@key_bindings)
      st.word == word && st.list && keys.key?("\e[B".bytes)
    end

    def prompt_line
      host = @tiles.instance_variable_get(:@host)
      host.synchronize { host.vt.lines }.reverse.find { |l| l.match?(/\At[>*] /) }&.rstrip
    end

    it 'lists matches as you type, Down and Tab or Enter pick, Esc closes, and Tab completes as before elsewhere' do
      @tiles, @term = ui_tiles(:tiles, rows: 30, cols: 100)
      expect(@term.wait_for('t> ')).to eq(true), @term.text
      @term.type('L.inst.r')
      expect(@term.wait_for(/reed_piano +instrument/)).to eq(true), @term.text
      @term.type('ee')
      expect(@term.wait_for(/jungle_reese +instrument/)).to eq(true), @term.text
      expect(wait_until { listed?('L.inst.ree') }).to eq(true)
      @term.write("\e[B")
      # (Reline holds the list's keys again once it has drawn the list:
      # keys typed apart, as people type them)
      expect(wait_until { ::Reline.dialog_proc(:mb_library).context.pointer == 1 }).to eq(true)
      @term.write("\t")
      expect(wait_until { prompt_line == 't> L.inst.dnb_reese' }).to eq(true), prompt_line.inspect

      # Enter picks too (a second Enter runs the line)
      @term.write("\x15") # (Ctrl-U: an empty line)
      @term.type('L.reese')
      expect(wait_until { listed?('L.reese') }).to eq(true)
      @term.write("\r")
      expect(wait_until { prompt_line == 't> L.inst.dnb_reese' }).to eq(true), prompt_line.inspect

      # Esc closes the list; typing on brings it back
      @term.write("\x15")
      @term.type('L.inst.ree')
      expect(wait_until { listed?('L.inst.ree') }).to eq(true)
      expect(@term.wait_for(/jungle_reese/)).to eq(true)
      @term.write("\e")
      expect(wait_until { ::Reline.dialog_proc(:mb_library).context.list.nil? && !@term.text.include?('jungle_reese') }).to eq(true), @term.text
      expect(prompt_line).to eq('t> L.inst.ree')

      # Outside head chains, Tab is Pry's completion
      @term.write("\x15")
      @term.type("[1].firs\t")
      expect(wait_until { prompt_line == 't> [1].first' }).to eq(true), prompt_line.inspect
    end

    it 'stays closed on a chain recalled from history, so Up goes on to older lines' do
      @tiles, @term = ui_tiles(:tiles, rows: 30, cols: 100)
      expect(@term.wait_for('t> ')).to eq(true), @term.text
      @term.type("6 * 7\r")
      expect(@term.wait_for('=> 42')).to eq(true), @term.text
      @term.type('e = L.fx.bar')
      expect(wait_until { listed?('L.fx.bar') }).to eq(true), @term.text
      @term.write("\e")
      expect(wait_until { ::Reline.dialog_proc(:mb_library).context.list.nil? }).to eq(true)
      @term.write("\r")
      # (run: its value, or a NameError where L isn't defined; history either way)
      expect(wait_until { @term.text.match?(/NameError|Entry bar/) && prompt_line == 't>' }).to eq(true), @term.text

      @term.write("\e[A")
      expect(wait_until { prompt_line == 't> e = L.fx.bar' }).to eq(true), prompt_line.inspect
      @term.write("\e[A")
      expect(wait_until { prompt_line == 't> 6 * 7' }).to eq(true), "#{prompt_line.inspect}\n#{@term.text}"
      expect(@term.text).not_to include('barberpole')

      # Typing on the recalled chain opens the list as before
      @term.write("\e[B")
      expect(wait_until { prompt_line == 't> e = L.fx.bar' }).to eq(true), prompt_line.inspect
      @term.type('b')
      expect(@term.wait_for(/barberpole +phaser/)).to eq(true), @term.text
    end

    # followups-1 (the maintainer, 2026-11-21: "Can the autocomplete scroll
    # beyond the few items listed?"): the list holds every match and
    # scrolls ten rows at a time
    it 'scrolls past the first ten matches with Down and PageDown, and picks one there' do
      @tiles, @term = ui_tiles(:tiles, rows: 30, cols: 100)
      expect(@term.wait_for('t> ')).to eq(true), @term.text
      @term.type('L.inst.a')
      expect(wait_until { listed?('L.inst.a') }).to eq(true), @term.text
      st = ::Reline.dialog_proc(:mb_library).context
      expect(st.list.length).to be > 20
      eleventh = st.list[10].entry.name.to_s
      expect(@term.text).not_to match(/^\s*#{Regexp.escape(eleventh)}\s/) # (below the ten rows shown)
      @term.write("\e[6~") # PageDown
      expect(wait_until { st.pointer == 10 }).to eq(true)
      expect(@term.wait_for(/#{Regexp.escape(eleventh)} +\w/)).to eq(true), @term.text
      @term.write("\e[B")
      expect(wait_until { st.pointer == 11 }).to eq(true)
      @term.write("\e[5~") # PageUp
      expect(wait_until { st.pointer == 1 }).to eq(true)
      @term.write("\e[6~")
      expect(wait_until { st.pointer == 11 }).to eq(true)
      want = st.list[11].chain
      @term.write("\t")
      expect(wait_until { prompt_line == "t> #{want}" }).to eq(true), "#{prompt_line.inspect} (want #{want})"
    end

    # followups-1 (the gvl-main-1 report: each key in a head chain listed
    # the shelves' documents anew, about 200 stats, ~40 ms of typing lag
    # over sshfs): in steady state the keys make no file calls on the
    # thread reading them; the documents come from the last scan, rescanned
    # in the background once stale (Library::Index::DOCUMENT_STALE)
    it 'makes no file calls on the REPL thread per key typed into a listed chain' do
      @tiles, @term = ui_tiles(:tiles, rows: 30, cols: 100)
      expect(@term.wait_for('t> ')).to eq(true), @term.text
      @term.type('L.inst.r') # (the first list: a scan where it runs)
      expect(wait_until { listed?('L.inst.r') }).to eq(true), @term.text
      host = @tiles.instance_variable_get(:@host)
      reader = host.thread || Thread.main
      calls = MB::Sound::UI::FileWatch.watch([reader]) do
        %w[e e s].each_with_index do |ch, i|
          @term.type(ch)
          expect(wait_until { listed?('L.inst.r' + 'ees'[0..i]) }).to eq(true), @term.text
        end
        @term.write("\x7f") # (a deletion lists again too)
        expect(wait_until { listed?('L.inst.ree') }).to eq(true), @term.text
      end
      expect(calls).to eq([]), calls.first(10).map(&:inspect).join("\n")
    end
  end
end
