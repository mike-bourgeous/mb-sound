# Clip/Kit transform parity (parity-1, 2026-10-30; backlog 12.5): a grid
# Kit transforms like the Clips of its rows, for every Kit transform,
# over seeded random kits.  A sweep (QuickSelection::ALWAYS): a new Kit
# transform goes in #transforms, and a fix to one adds its case here.
RSpec.describe('Clip and Kit transform parity', :aggregate_failures) do
  let(:s) { MB::Sound }
  let(:kit_class) { MB::Sound::Sequence::Kit }

  # [name, code after the receiver, seeded?]: seeded transforms give each
  # Kit row its own seed (Kit.row_seed), passed to the row's Clip call as
  # seed: (SEED stands for it).
  def transforms = [
    ['reverse', 'reverse', false],
    ['rotate later', 'rotate(1.n16)', false],
    ['rotate earlier', 'rotate(-3/16r)', false],
    ['shift later', 'shift(1.n8)', false],
    ['shift earlier', 'shift(-1/16r)', false],
    ['swing', 'swing(0.6)', false],
    ['swing 8ths', 'swing(2/3r, 8)', false],
    ['quantize', 'quantize(8, amount: 0.5)', false],
    ['chance', 'chance(0.5)', false],
    ['every', 'every(2, from: 2)', false],
    ['ratchet', 'ratchet(2)', false],
    ['ratchet at a rate', 'ratchet(3, rate: 1.n32, velocity: 1.0..0.5)', false],
    ['humanize', 'humanize(1.n64, velocity: 0.2%s)', true],
    ['permute', 'permute(%s)', true],
  ].freeze

  def chars = %w[x X . . . ? 5]

  # A seeded random grid kit: 1-4 rows of GM drums, all +steps+ long
  # (polymetric: 4, 6, or 8 steps a row) at 16ths, maybe looping.
  def random_kit(rng, polymeter: false)
    names = %i[kick snare closed_hat open_hat clap low_tom].shuffle(random: rng).first(rng.rand(1..4))
    steps = [4, 8][rng.rand(2)]
    rows = names.to_h { |n|
      len = polymeter ? [4, 6, 8][rng.rand(3)] : steps
      [n, Array.new(len) { chars[rng.rand(chars.length)] }.join]
    }
    kit = s.grid(16, seed: rng.rand(100), **rows)
    rng.rand < 0.5 ? kit.loop : kit
  end

  def rows(clip)
    clip.events.map { |e| [e.start, e.length, e.value, e.velocity.round(9), e.probability, e.condition, e.accented] }.sort_by(&:inspect)
  end

  def apply(receiver, code, seed = nil)
    receiver.instance_eval(apply_text(code, seed))
  end

  it 'transforms each row like the row clip (seeded transforms from Kit.row_seed)' do
    rng = Random.new(RSpec.configuration.seed)
    12.times do
      kit = random_kit(rng, polymeter: rng.rand < 0.5)
      transforms.each do |label, code, seeded|
        seed = seeded ? rng.rand(1000) : nil
        got = apply(kit, code, seed)
        expect(got).to be_a(kit_class)
        expect(got.rows.keys).to eq(kit.rows.keys)
        kit.each do |name, row|
          want = seeded ? apply(row, code, kit_class.row_seed(seed, name)) : apply(row, code)
          expect(rows(got[name])).to eq(rows(want)), "#{label} of #{name} in #{kit}"
          expect(got[name].looping?).to eq(row.looping?)
          expect(got[name].length).to eq(want.length)
        end
      end
    end
  end

  it 'stacks to the same notes as the stacked kit transformed, for rows of one length' do
    rng = Random.new(RSpec.configuration.seed + 1)
    12.times do
      kit = random_kit(rng)
      transforms.reject { |*, seeded| seeded }.each do |label, code, _|
        expect(rows(apply(kit, code).to_clip)).to eq(rows(apply(kit.to_clip, code))), "#{label} of #{kit}"
      end
    end
  end

  it 'gives rows their own seeds, the same in every process' do
    a = kit_class.row_seed(3, :kick)
    expect(a).to eq(kit_class.row_seed(3, :kick))
    expect(a).not_to eq(kit_class.row_seed(3, :snare))
    expect(a).not_to eq(kit_class.row_seed(4, :kick))
    expect(kit_class.row_seed(0, :kick)).to eq(MB::Sound::Generative::Dice.fold(MB::Sound::Generative::Dice.start(0), :kit_row, :kick) & ((1 << 62) - 1))

    beat = s.grid(16, kick: 'x.x.x.x.', hat: 'x.x.x.x.').loop.humanize(4.ms)
    expect(beat[:kick].events_for(1).map(&:start)).not_to eq(beat[:hat].events_for(1).map(&:start))
  end

  it 'permutes rows by a Hash of orders, leaving others alone' do
    kit = s.grid(16, kick: 'X.x.', hat: 'xX5x')
    got = kit.permute(hat: [3, 2, 1, 0])
    expect(rows(got[:kick])).to eq(rows(kit[:kick]))
    expect(got[:hat].events.map { |e| e.velocity.round(3) }).to eq(kit[:hat].events.map { |e| e.velocity.round(3) }.reverse)
  end

  it 'prints Kit transforms as Ruby that rebuilds the same rows' do
    rng = Random.new(RSpec.configuration.seed + 2)
    4.times do
      kit = random_kit(rng)
      transforms.each do |label, code, seeded|
        got = apply(kit, code, seeded ? 7 : nil)
        text = got.to_ruby
        expect(text).to include(".#{code[/\A\w+/]}"), label
        again = MB::Sound.module_eval(text)
        kit.rows.each_key { |name| expect(rows(again[name])).to eq(rows(got[name])), "#{label}: #{text}" }
      end
    end
  end

  def apply_text(code, seed)
    code.sub('%s', seed.nil? ? '' : (code.include?('(%s)') ? "seed: #{seed}" : ", seed: #{seed}"))
  end

  # Clip methods that grid Kits don't mirror, with the reason.  A new
  # public Clip method fails the guard below until Kit has it (and
  # #transforms sweeps it) or it is listed here.
  def kit_exempt
    {
      'readers, playback plumbing, and lineage' => %i[
        align control control_chase control_edges control_horizon controls controls? edge_horizon edges event_at event_before events
        events_for launch_aligned? length lineage looping? param_nodes performed? plays? rederive seed source steer_lead steered? stream
        value value_at values variations with_controls without_controls fit_controls rhythm
      ],
      'signal nodes of one note stream (a kit plays through a drum machine: tr808(kit), kit.to_clip.gate)' => %i[
        amp_env amp_envelope env envelope filt_env filter_env filter_envelope fm_env fm_envelope freq frequency gate hz notes number
        period pitch tone trigger velocity synth sampler tween
      ],
      'stream transforms returning a MIDI::Stream (per row they would make one stream per row)' => %i[arp chord degrees echo lock snap strum through],
      'clocks (kits play on their player\'s clock: track ..., clock:)' => %i[% at clock clocked clocked_at clocking over],
      'pitch moves: a kit row is a drum voice, so moving its note moves it to another voice' => %i[transpose ghost_chords],
      'combining and resizing clips (kits combine with Kit#fill, rows by name)' => %i[& | * repeat truncate bake roll],
      'note lengths: drum voices ignore them (Kit#legato is there for gated kits)' => %i[d dd dotted double_dotted t triplet note_length staccato],
      'vel (omnibus18 is changing its clamping; add Kit#vel there)' => %i[vel],
    }
  end

  it 'mirrors every Clip transform on Kit or says why not (parity guard)' do
    clip_methods = MB::Sound::Sequence::Clip.public_instance_methods - Object.public_instance_methods
    missing = clip_methods - kit_class.public_instance_methods - kit_exempt.values.flatten
    expect(missing.sort).to eq([]), "Clip methods missing from Kit (add them to Kit and #transforms, or to #kit_exempt with a reason): #{missing.sort.join(' ')}"
    swept = transforms.map { |_, code, _| code[/\A\w+/].to_sym }.uniq
    mirrored = kit_class.public_instance_methods(false) & clip_methods
    unswept = mirrored - swept - %i[each show loop stretch halftime half_time doubletime double_time legato fill nofill groove maybe shuffle retrograde]
    expect(unswept.sort).to eq([]), "Kit transforms the parity sweep doesn't run: #{unswept.sort.join(' ')}"
  end

  it 'shows random kits as grid rows that parse back to the same rows' do
    rng = Random.new(RSpec.configuration.seed + 3)
    12.times do
      kit = random_kit(rng, polymeter: rng.rand < 0.5)
      again = s.grid(16, **kit.show.rows)
      kit.each { |name, row| expect(rows(again[name])).to eq(rows(row)), "#{kit.show}" }
    end
  end

  it 'loads Kit transforms from graph documents' do
    text = "graph #{MB::Sound::GraphIO::FORMAT}\ntr808(grid(16, kick: 'x...x...', hat: 'x.x.x.x.').reverse.rotate(1.n16).shift(1.n16).swing(0.6).humanize(4.ms).chance(0.9).ratchet(2).loop)\n"
    g = MB::Sound::GraphIO.load(text)
    expect(g.to_ruby).to include('.reverse.rotate(1.n16).shift(1.n16).swing(0.6).humanize(4.ms).chance(0.9).ratchet(2).loop')
  end
end
