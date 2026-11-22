# Format names stay at the edges (metadata-2, round 2; the maintainer,
# 2026-11-11: "I'd like "ACID" as a concept to stay at the edges of the
# app, and more generalized concepts to propagate into the library").
#
# Format words (ACID, its `strc` chunk, `smpl`, REX, .acd) belong to the
# edges: readers and writers of formats, interpreters of their facts,
# importers and converters, exporters, and provenance values (`via:
# :acid`, a Provenance naming the chunk).  The library's API, DSL,
# options, help, and vocabulary speak in general concepts: loop,
# one-shot, beats, root, stretch markers, slice points.  So no
# `acid_one_shot?`, no `strc:` option, no stretch mode named after a
# format.
#
# A Prism scan of lib/ for method names, keyword parameter names, help
# topic names, and Symbol literals with a format word as one of their
# words: each must sit in an EDGES file (with why it is an edge), or be
# the TB-303 sense of "acid" (MUSICAL: acid lines, acid basses, the
# `.acid` transform, a genre's :acid patch), or be an open question
# (QUESTIONS).  design/notes/metadata.md, "Format names at the edges".
require 'prism'

module FormatWords
  ROOT = File.expand_path('../../../..', __dir__)

  # Format words, matched as whole words of a name (`acid_env` has the word
  # acid; `placid` doesn't).
  WORDS = %w[acid strc smpl rex acd].freeze

  # Files at the edges, where format words belong, with why.
  EDGES = {
    'lib/mb/sound/sample/riff.rb' => 'the WAV chunk reader and fixture writer (acid, smpl, strc chunks)',
    'lib/mb/sound/sample/loop_info.rb' => 'the loop file interpreter: reads the acid, smpl, and strc chunks, names them in provenance',
    'lib/mb/sound/midi/control_map.rb' => 'the exporter of controller maps as ACID XML (to_acid_xml)',
    'lib/mb/sound/script_runner.rb' => 'the scripts\' --acid-xml option, the exporter\'s edge',
    'lib/mb/sound/help/content/topics.rb' => 'help :meta\'s importer example, a provenance value (`format: :acd`)',
  }.freeze

  # The TB-303 sense of "acid" (a musical term, not a format), by "file:
  # name".
  MUSICAL = {
    'lib/mb/sound/genre/patches.rb: acid' => 'the acid bass patch (TB-303)',
    'lib/mb/sound/genre/techno.rb: acid' => 'acid techno\'s bass (TB-303)',
    'lib/mb/sound/hand_tune/wizard.rb: acid' => 'acid bass as a bass role (TB-303)',
    'lib/mb/sound/help/content/lessons.rb: acid_rhythm' => 'an acid line\'s rhythm (TB-303)',
    'lib/mb/sound/help/content/topics.rb: acid' => 'help :sequences lists the .acid transform (TB-303)',
    'lib/mb/sound/library/bench/materials.rb: acid' => 'an acid bass material (TB-303)',
    'lib/mb/sound/library/generators/generative_steer.rb: acid' => 'acid line generators (TB-303)',
    'lib/mb/sound/library/generators/generative_steer.rb: acid_rhythm' => 'acid line generators (TB-303)',
    'lib/mb/sound/notes.rb: acid_env' => 'the TB-303 accent envelope',
    'lib/mb/sound/sequence/seq.rb: acid' => 'the .acid transform (TB-303 accents and slides)',
    'lib/mb/sound/sequence_methods.rb: acid' => 'the acid line builder (TB-303)',
  }.freeze

  # Format words in the library's vocabulary still, each an open question
  # for the maintainer.
  QUESTIONS = {}.freeze

  module_function

  # [file, line, kind, name] for each name with a format word in +source+.
  def names(source, file)
    out = []
    stack = [Prism.parse(source).value]
    until stack.empty?
      n = stack.pop
      case n
      when Prism::DefNode
        out << [file, n.location.start_line, 'method', n.name.to_s]
        (n.parameters&.keywords || []).each { |k| out << [file, k.location.start_line, 'keyword option', k.name.to_s] }
      when Prism::SymbolNode
        out << [file, n.location.start_line, 'Symbol', n.unescaped] if n.unescaped
      when Prism::CallNode
        if n.name == :topic && n.receiver&.slice&.end_with?('Help') && (a = n.arguments&.arguments&.first).is_a?(Prism::SymbolNode)
          out << [file, n.location.start_line, 'help topic', a.unescaped]
        end
      end
      stack.concat(n.compact_child_nodes)
    end
    out.select { |_, _, _, name| format_word?(name) }.sort_by { |_, l, _, _| l }
  end

  def format_word?(name)
    !(name.downcase.split(/[^a-z0-9]+/) & WORDS).empty?
  end

  def problems(found)
    found.filter_map do |file, line, kind, name|
      next if EDGES.key?(file) || MUSICAL.key?("#{file}: #{name}") || QUESTIONS.key?("#{file}: #{name}")
      "#{file}:#{line}: #{kind} #{name.inspect} names a format: the library speaks in general concepts (loop, one-shot, beats, root, stretch markers, slice points); keep format names in readers, interpreters, importers, exporters, and provenance (EDGES), or list a musical sense in MUSICAL"
    end.uniq
  end

  def all
    @all ||= Dir[File.join(ROOT, 'lib/**/*.rb')].sort.flat_map { |path| names(File.read(path), path.delete_prefix("#{ROOT}/")) }
  end
end

RSpec.describe('format names stay at the edges') do
  it 'finds format words in method, option, help topic, and Symbol names only at the edges or in their musical sense' do
    expect(FormatWords.problems(FormatWords.all)).to eq([])
  end

  it 'lists only edges and names that are still there' do
    files = FormatWords.all.map(&:first).uniq
    stale_edges = FormatWords::EDGES.keys.reject { |f| files.include?(f) }
    keys = FormatWords.all.map { |f, _, _, n| "#{f}: #{n}" }.uniq
    stale = (FormatWords::MUSICAL.keys + FormatWords::QUESTIONS.keys).reject { |k| keys.include?(k) }
    expect(stale_edges + stale).to eq([])
  end

  it 'catches a format word in a library method or option, and not inside other words' do
    src = "def acid_one_shot? = true\ndef stretch(strc: nil) = 1\ndef placid = :parex\n"
    found = FormatWords.names(src, 'lib/mb/sound/sample.rb')
    expect(found.map { |_, _, k, n| [k, n] }).to eq([['method', 'acid_one_shot?'], ['keyword option', 'strc']])
    expect(FormatWords.problems(found).length).to eq(2)
    expect(FormatWords.problems(FormatWords.names("def acid = 1\n", 'lib/mb/sound/sequence/seq.rb'))).to eq([])
  end
end
