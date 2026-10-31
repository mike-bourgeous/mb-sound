# The design notes index and CLAUDE.md's topic map stay generated from the
# notes' summary blocks, and no fact of the old Architecture section is lost
# (docs-split-1; spec/docs_index.rb).
require_relative 'docs_index'

RSpec.describe('design notes index') do
  it 'has a summary block and a group for every note' do
    expect(DocsIndex.note_problems).to eq([])
  end

  it 'starts every note with a short Quick reference whose paths exist' do
    expect(DocsIndex.quick_reference_problems).to eq([])
  end

  it 'reports Quick references that are missing, misplaced, long, or name missing paths' do
    note = ->(quick, rest = "Text.\n") { "# T\n\n<!-- summary -->\nS.\n<!-- /summary -->\n\n#{quick}#{rest}" }
    expect(DocsIndex.quick_problems_of('n', note.("## Quick reference\n\n- `bin/sound.rb`\n\n"))).to eq([])
    expect(DocsIndex.quick_problems_of('n', note.(''))).to eq(["n has no '## Quick reference' of '- ' bullets right after its summary block"])
    expect(DocsIndex.quick_problems_of('n', note.("Intro.\n\n## Quick reference\n\n- a\n\n"))).to include(/no '## Quick reference'/)
    expect(DocsIndex.quick_problems_of('n', note.("## Quick reference\n\n#{"- a\n" * 7}\n"))).to eq(["n's Quick reference has 7 bullets (1-6)"])
    expect(DocsIndex.quick_problems_of('n', note.("## Quick reference\n\n- #{'x' * 1800}\n\n"))).to eq(["n's Quick reference is 1803 bytes (at most 1800)"])
    expect(DocsIndex.quick_problems_of('n', note.("## Quick reference\n\n- `bin/nope.rb`\n\n", "## Quick reference\n"))).to eq(
      ['n has 2 Quick reference headings', "n's Quick reference names bin/nope.rb, which doesn't exist"]
    )
  end

  it 'is current in design/notes/README.md and CLAUDE.md' do
    expect(DocsIndex.stale_problems).to eq([])
  end

  it 'keeps every term of the old Architecture section in CLAUDE.md, the index, or a note' do
    missing = DocsIndex.missing_terms.map { |section, t| "#{section}: #{t}" }
    expect(missing).to eq([]), "#{missing.join("\n")}\n" \
      "Move these facts into their design note, or, if a term is gone on purpose, delete its line from spec/docs/architecture_terms.txt"
  end

  it 'names only existing notes in CLAUDE.md' do
    expect(DocsIndex.dangling_references).to eq([])
  end

  it 'keeps CLAUDE.md within its size budget (skips with the biggest sections when over)' do
    warning = DocsIndex.size_warning
    skip(warning) if warning
    expect(DocsIndex.claude_text.bytesize).to be <= DocsIndex::BUDGET
  end

  it 'reports sizes over a budget with the biggest sections' do
    expect(DocsIndex.size_warning(budget: 1000)).to match(/over its 1 KB budget.*biggest sections: ##/)
  end
end
