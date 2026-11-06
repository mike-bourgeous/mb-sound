require 'prism'
require_relative '../../../../support/graph_sweep'
require_relative '../../../../support/recipe_helpers'

# The load-with-param sweep (fit-patch-2, proposed by hand-tune-1): every
# DSL setting either takes a graph document's param (a live node, or a
# number read while the graph builds: GraphNode.build_setting) or is listed
# in GraphIO::NumberOnly with why.  Every graph sweep factory's document
# (and the probes below) is written with each Float literal FitPatch could
# turn into a param as a `param` line; a literal whose param doesn't load
# and play must sit at a listed setting, and every listed setting must
# refuse a param somewhere here (no stale entries).  Then the documents as
# FitPatch writes them (listed settings left as numbers) load and play the
# numbers' samples, so every fit of these shapes loads.  Integer literals
# (counts, seeds, notes, voices) are structure, out of the sweep.
module NumberOnlySweep
  module_function

  def io = MB::Sound::GraphIO

  # [document text with the chosen literals as params, [[literal, setting]]]:
  # +doc+'s literals that FitPatch could make params (no Range, typed
  # value, or runtime block; with +number_only+ also not at a NumberOnly
  # setting), all of them or those at +only+ (indices).
  def paramify(doc, number_only:, only: nil)
    fp = MB::Sound::FitPatch
    body = fp.body_of(doc)
    at = doc.rindex(body)
    found = []
    fp.literals(Prism.parse(body).value, number_only: number_only) do |node, _key, why, setting|
      found << [node, setting] if why.nil? && node.is_a?(Prism::FloatNode)
    end
    found = found.values_at(*only) if only
    out = body.b
    lines = []
    found.each_with_index.sort_by { |(n, _), _| -n.location.start_offset }.each do |(n, _), i|
      out[n.location.start_offset...n.location.end_offset] = "sweep_p#{i}".b
      lines << "param :sweep_p#{i}, #{n.slice}"
    end
    [doc[0...at] + lines.sort.join("\n") + "\n\n" + out.force_encoding(body.encoding), found]
  end

  # Loads +text+ and renders it (nil), or the error it raised.
  def problem(text, inputs: {})
    g = io.load(text, inputs: inputs)
    RecipeHelpers.render(g, buffers: 6, size: 128)
    nil
  rescue StandardError, ScriptError => e
    e
  end

  # Documents whose params (constant nodes at the numbers' values) play
  # other samples than the numbers, with why.  An entry that plays the
  # numbers' samples again fails (remove it).  fix-batch-1106 emptied it:
  # both entries were a number read as a double where a node's samples
  # are floats (Tone's warp width and pivot; a feedback loop's steady
  # params), which numbers now read as the float too (complex_square's
  # pwm(0.3) and pwm(0.3.constant) were -23.7 dB apart, a warp edge landing
  # exactly on a sample at 220 Hz; a loop allpass's quality -50 dB, its
  # pitch latency unwrapping to another period).
  KNOWN = {}.freeze

  # Code beyond the factories: settings the factories don't reach, and the
  # shapes the hand-tune queue's fits print (synthetic; no private code).
  PROBES = {
    'Pitch filter objects' => '220.hz.saw.filter(3000.hz.highpass(quality: 0.5)).filter(800.hz.lowpass(quality: 0.7))',
    'a clap fit: bursts, repeats, decay_env, MB::Sound.noise' =>
      "kit(grid(16, clap: 'X...'), seed: 1) { voice(:clap) { |h| b = h.bursts(4, 0.0111, falloff: 1.0166); " \
      'env = MB::Sound::Drums.decay_env(b, 0.0203, curve: 30) + MB::Sound::Drums.decay_env(MB::Sound::Drums::Repeats.new(h.t, [[0.0223, 1.0]]), 0.5551) * 0.188 + ' \
      'h.env(0.3, trigger: h.repeats([[0.031, 0.5]])) * 0.1; ' \
      'MB::Sound.noise.filter(:bandpass, cutoff: 1046.66, quality: 1.8728).filter(:highpass, cutoff: 207.98, quality: 0.7) * env * 4.4 } }',
    'a seeded voice: with_seed' =>
      'with_seed(1) { synth(seq(C4).len(1/4r), voices: 1) { |v| v.hz.unison(3, detune: 12.cents, mix: 0.8) { |c, _i| c.saw } * v.env(0.0345, 0.5342, 0.2681, 0.05) + noise * 0.0195 } }',
    'a build-time then: DSL calls on its argument' =>
      '220.hz.saw.then { |u| u + u * u * 0.2541 }.then { |x| c = 2 ** (0.4.hz.lfo.triangle * 1.6244) * 665.1; ap = x.filter(:allpass, cutoff: c, quality: 0.5); ' \
      'ap = ap.filter(:allpass, cutoff: c, quality: 0.5); x + ap * 0.221 }.softclip(0.1729, 1.0)',
    'settings read once while building' =>
      '220.hz.saw.smooth(0.0021).until(0.5).sounding(hold: 0.25, fade: 0.0125).decimate(8000, jitter: 0.25) + ' \
      'MB::Sound.silence(0.0123) + 220.hz.saw.noise(0.3) + 110.hz.saw.filter(:peak, cutoff: 900, quality: 0.7, gain: 1.5, structure: :biquad)',
  }.freeze

  # [name, document text, inputs] for each factory that writes as a document
  # and each probe.
  def documents
    @documents ||= begin
      list = GraphSweep.factories.filter_map do |name, factory|
        MB::Sound.seed(1)
        graph = factory.call(GraphSweep::Context.new)
        [name, io.dump(graph, name: 'sweep'), {}]
      rescue MB::Sound::GraphIO::DumpError
        nil # (graph_io_spec lists the factories that can't be written, and why)
      end
      # (probes load as written: a dump would print what with_seed and
      # then built, not the blocks)
      list + PROBES.map { |name, code| [name, "graph #{io::FORMAT}, name: \"probe\"\n\n#{code}\n", {}] }
    end
  end

  # { setting => [[document name, literal text, error message], ...] } for
  # every literal whose param alone fails, and the count of literals swept.
  def refusals
    @refusals ||= begin
      out = Hash.new { |h, k| h[k] = [] }
      count = 0
      documents.each do |name, doc, inputs|
        text, found = paramify(doc, number_only: false)
        count += found.length
        next if problem(text, inputs: inputs).nil?
        found.each_index do |i|
          one, = paramify(doc, number_only: false, only: [i])
          e = problem(one, inputs: inputs)
          out[found[i][1]] << [name, found[i][0].slice, e.message.lines.first.strip] if e
        end
      end
      [out, count]
    end
  end
end

RSpec.describe(MB::Sound::GraphIO::NumberOnly) do
  let(:sweep) { NumberOnlySweep }

  it 'lists every setting where a param fails to load, and nothing else (the load-with-param sweep)' do
    refused, count = sweep.refusals
    expect(count).to be > 500
    unlisted = refused.reject { |setting, _| described_class.reason(setting) }
    list = unlisted.map { |st, sites| "#{MB::Sound::FitPatch.setting_name(st)} (#{sites.map { |n, lit, msg| "#{n}: #{lit}: #{msg}" }.first(2).join('; ')})" }
    expect(list).to eq([]), "settings that take only numbers: #{list.join("\n")}\nmake them read a param while building " \
                            '(GraphNode.build_setting), or list them in GraphIO::NumberOnly with why'

    stale = described_class.entries.reject { |call, arg, _|
      refused.keys.any? { |c, a| (call.is_a?(Regexp) ? call.match?(c) : call == c) && (arg == :* || arg == a) }
    }
    names = stale.map { |c, a, _| "#{c.is_a?(Regexp) ? c.source : c}(#{a})" }
    expect(names).to eq([]), "GraphIO::NumberOnly entries that took a param everywhere in the sweep: #{names.join(', ')}; " \
                             'remove them (or add a probe that still refuses)'
  end

  it 'loads every document with its other literals as params, playing the numbers\' samples (what FitPatch writes)' do
    worst = sweep.documents.filter_map { |name, doc, inputs|
      text, found = sweep.paramify(doc, number_only: true)
      next if found.empty?
      e = sweep.problem(text, inputs: inputs)
      next "#{name}: #{e.class}: #{e.message.lines.first.strip}" if e

      MB::Sound.seed(3)
      ref = RecipeHelpers.render(sweep.io.load(doc, inputs: inputs), buffers: 6, size: 128)
      MB::Sound.seed(3)
      got = RecipeHelpers.render(sweep.io.load(text, inputs: inputs), buffers: 6, size: 128)
      diff = RecipeHelpers.max_diff(ref, got)
      peak = [ref.map { |c| c.length == 0 ? 0 : c.abs.max }.max.to_f, 1e-9].max
      "#{name}: #{(20 * Math.log10(diff / peak)).round(1)} dB" if diff > peak * 10**(-100 / 20.0)
    }
    expect(worst.map { |w| w.sub(/: [^:]*\z/, '') }).to match_array(NumberOnlySweep::KNOWN.keys), worst.join("\n")
  end

  it 'names each setting the way FitPatch reports it' do
    expect(MB::Sound::FitPatch.setting_name(['tween', 0])).to eq('tween(0)')
    expect(MB::Sound::FitPatch.setting_name(['lowpass', :quality])).to eq('lowpass(quality:)')
    expect(MB::Sound::FitPatch.setting_name(['constant', :self])).to eq('constant(receiver)')
    expect(described_class.reason(['Filter::Biquad.new', 2])).to match(/filter objects/)
    expect(described_class.reason(['Drums::Repeats.new', 1])).to be_nil
    expect(described_class.reason(nil)).to be_nil
  end
end
