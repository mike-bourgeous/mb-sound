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
  end
end
