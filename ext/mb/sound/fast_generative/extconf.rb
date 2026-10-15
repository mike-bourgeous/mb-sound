require 'mkmf'

# No NArray or shared headers: the dice work on Ruby Integers, Symbols,
# Strings, Rationals, and Arrays of Floats.

# -ffp-contract=off: specs compare #pick's compensated sum with its Ruby
# mirror (MB::Sound::Generative::Dice, mode :ruby) and with Array#sum for
# exact equality, so clang (the default on macOS) must not fuse multiplies
# and adds into FMAs.
with_cflags("#{$CFLAGS} -O3 -ggdb3 -Wall -Wextra -Werror -Wno-unused-parameter #{ENV['EXTRACFLAGS']} -ffp-contract=off -std=c99 -D_XOPEN_SOURCE -D_ISOC99_SOURCE -D_GNU_SOURCE") do
  create_makefile('mb/sound/fast_generative')
end
