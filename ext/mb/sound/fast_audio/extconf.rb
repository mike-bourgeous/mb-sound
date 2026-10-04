require 'mkmf'

# This require line ensures that the narray gem spec is loaded when installing this extension
require 'numo/narray'

# Used numo-pocketfft as a reference for finding narray.h
# https://github.com/yoshoku/numo-pocketfft/blob/1ab489b165d4cde06b6d3a443ed9bfbc8e5c69d0/ext/numo/pocketfft/extconf.rb
# https://stackoverflow.com/questions/9322078/programmatically-determine-gems-path-using-bundler
na = Gem.loaded_specs['numo-narray-alt'] || Gem.loaded_specs['numo-narray']
raise "Could not find the numo-narray Gem; try running with Bundler" if na.nil?
raise 'Could not find narray.h' unless find_header('numo/narray.h', File.join(na.extension_dir, 'numo'))

# miniaudio (vendored in miniaudio.h) loads its audio backends (CoreAudio on
# macOS; PulseAudio, ALSA, and JACK on Linux) at runtime, so no audio
# packages are needed to build.  It needs threads, math, and dlopen.
have_library('pthread')
have_library('m')
have_library('dl')

# gnu11 for C11 atomics in the ring buffer
with_cflags("#{$CFLAGS} -O3 -ggdb3 -Wall -Wextra -Werror -Wno-unused-parameter #{ENV['EXTRACFLAGS']} -std=gnu11") do
  create_makefile('mb/sound/fast_audio')
end
