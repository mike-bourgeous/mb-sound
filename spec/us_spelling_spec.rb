# The maintainer prefers US spellings (2026-11-24): the project's own
# tracked text (code, comments, specs, notes, help, presets) uses them.
# This guard greps every tracked text file for British forms and names
# the US form to write instead.  "Cancelled" (and "cancelling",
# "cancellation") is accepted, so it is not listed.  Idioms ("different
# to", "has got to") are left to review: their US readings collide.
module USSpelling
  # British form => the US form to write.  Each pattern matches whole
  # words, any case; suffixes are listed so plain US words ("realistic",
  # "Marvell", "emphasis", "programmed") don't match.
  FORMS = {
    /\bcolour(s|ed|ing|ful|less)?\b/i => 'color',
    /\bbehaviour(s|al)?\b/i => 'behavior',
    /\bfavour(s|ed|ing|able|ite|ites)?\b/i => 'favor, favorite',
    /\bflavour(s|ed|ing)?\b/i => 'flavor',
    /\bneighbour(s|ing|hood|ly)?\b/i => 'neighbor',
    /\bhonour(s|ed|ing)?\b/i => 'honor',
    /\b(humour|labour|harbour|rumour|vapour|armour|endeavour|savour|odour|valour|parlour)(s|ed|ing)?\b/i => 'humor, labor, ... (-or)',
    /\b(centre|metre|litre|fibre|theatre|calibre|sombre|spectre|lustre|meagre)(s|d)?\b/i => 'center, meter, liter, fiber, ... (-er)',
    /\bartefacts?\b/i => 'artifact',
    /\blicence(s|d)?\b/i => 'license',
    /\b(defence|offence|pretence)s?\b/i => 'defense, offense, pretense',
    /\b(catalogue|analogue)(s|d)?\b/i => 'catalog, analog',
    /\bgrey(s|ed|ing|ish|er)?\b/i => 'gray',
    /\b(recogn|organ|optim|normal|initial|synchron|quant|real|minim|maxim|summar|visual|serial|random|custom|priorit|categor|special|util|standard|stabil|character|general|harmon|digit|local|token|vector|capital|equal|linear|parametr|apolog|memor|emphas|final|author|critic|neutral|central|symbol|polar|sanit|penal|discret|modern|familiar|subsid|fertil|mobil|sympath)is(e|ed|es|er|ers|ing|ation|ations)\b/i => '-ize, -ization',
    /\b(analy|paraly|cataly)s(e|ed|es|ing)\b/i => 'analyze, paralyze, catalyze',
    /\b(model|label|travel|signal|level|fuel|dial|channel|tunnel|total|equal|counsel|marvel)l(ed|ing|er|ers|ous)\b/i => 'modeled, labeling, traveled, ... (one l)',
    /\btowards\b/i => 'toward',
    /\bamongst\b/i => 'among',
    /\bwhilst\b/i => 'while',
    /\b(learnt|spelt|dreamt)\b/i => 'learned, spelled, dreamed',
    /\bprogrammes?\b/i => 'program',
    /\bjudgements?\b/i => 'judgment',
    /\bageing\b/i => 'aging',
    /\bpractis(e|ed|es|ing)\b/i => 'practice (the verb)',
    /\b(fulfil|enrol|instal|skilful|wilful|fulfilment|enrolment|instalment)\b/i => 'fulfill, enroll, install, skillful, willful',
    /\b(aluminium|maths|mould|plough|tyres?|cheques?|storeys?|kerb|draughts?|jewellery|pyjamas|sceptic(al)?|manoeuvr\w*)\b/i => 'aluminum, math, mold, plow, tire, check, story, curb, draft, jewelry, pajamas, skeptic, maneuver',
  }.freeze

  # [path, word, reason]: words that stay where they are.
  ALLOWED = [
    ['ext/mb/sound/fast_filter/fast_filter.c', 'Optimised', 'a published name (Cytomic\'s "Linear Trap Optimised" SVF)'],
    ['.claude/collaboration.md', 'judgement', 'the maintainer\'s own words, quoted'],
  ].freeze

  # Files that are not the project's own text.
  VENDORED = [
    'ext/mb/sound/fast_audio/miniaudio.h',
    'ext/mb/sound/fast_midi/RtMidi.cpp',
    'ext/mb/sound/fast_midi/RtMidi.h',
    'ext/mb/sound/fast_midi/RtMidi-LICENSE',
  ].freeze
end

RSpec.describe('US spelling') do
  forms = USSpelling::FORMS
  allowed = USSpelling::ALLOWED
  root = File.expand_path('..', __dir__)

  it 'finds no British spellings in the tracked text' do
    skip 'not a git checkout' unless File.exist?(File.join(root, '.git'))

    # git grep finds the candidate lines in every tracked text file (-I
    # skips binary ones) in a fraction of a second; Ruby then names each
    # word and its US form.
    pattern = forms.keys.map { |re| "(?:#{re.source})" }.join('|')
    excluded = (USSpelling::VENDORED + ['spec/us_spelling_spec.rb']).map { |f| ":(exclude)#{f}" }
    out = IO.popen(['git', '-C', root, 'grep', '-P', '-i', '-I', '-n', '--no-color', '-e', pattern, '--', '.', *excluded], err: File::NULL, &:read)
    expect($?.exitstatus).to be <= 1, 'git grep failed'

    hits = out.force_encoding(Encoding::UTF_8).scrub.each_line.flat_map do |hit|
      f, n, line = hit.split(':', 3)
      forms.flat_map do |re, us|
        line.to_enum(:scan, re).map { Regexp.last_match[0] }.filter_map do |word|
          next if allowed.any? { |file, w, _| file == f && w == word }

          "#{f}:#{n}: #{word} (write #{us})"
        end
      end
    end

    expect(hits).to eq([]), "British spellings (US forms preferred; USSpelling::ALLOWED in spec/us_spelling_spec.rb lists exceptions with reasons):\n#{hits.join("\n")}"
  end

  it 'lists each allowed word where it still appears' do
    stale = allowed.reject { |file, word, _| File.exist?(File.join(root, file)) && File.read(File.join(root, file)).include?(word) }
    expect(stale).to eq([])
  end
end
