require_relative 'fast_sampler'

module MB
  module Sound
    # The sampler (see design/notes/sampler.md): Sample values played by
    # GraphNode::SamplerVoice nodes through Sampler::Instrument key maps,
    # with chop clips, SFZ import, bouncing and capture (SamplerMethods).
    module Sampler
      # Loop mode codes in the kernel's region table (see Sample::LOOP_MODES).
      LOOP_MODES = { no_loop: 0, one_shot: 1, forward: 2, ping_pong: 3, release: 4 }.freeze

      # Samples over which a re-struck voice fades its old note (1.3 ms).
      DECLICK = 64

      # Clip#sampler: plays the clip on a sampler instrument.
      module ClipMethods
        # A synth playing this clip on +instrument+ (an Instrument, Sample,
        # or Slices; see MB::Sound#sampler), one voice by default.
        #
        #     bg :breaks, amen.sampler(brk)
        def sampler(instrument, voices: 1, **options, &block)
          MB::Sound.sampler(self, instrument, voices: voices, **options, &block)
        end
      end
    end
  end
end

require_relative 'sample'
require_relative 'sampler/kernel_ruby'
require_relative 'sampler/zone_map'
require_relative 'sampler/instrument'
require_relative 'sampler/sfz'
require_relative 'sampler/sf2'
require_relative 'sampler/capture'

MB::Sound::Sequence::Clip.include(MB::Sound::Sampler::ClipMethods)
