# mb-sound set document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 15,
  name: "n109",
  kind: :set,
  saved: "2026-11-22T05:55:22Z",
  mb_sound: "0.12.0.usegit (f82d8de)",
  from: "bin/songs/n109.rb",
  description: "Set :n109 from bin/songs/n109.rb (\"N109\", Kez Volta's half-time drum & bass at 174 BPM in F Phrygian, its second version): rain, vinyl, the bounced ghost voice and its answer, five clack kit tracks, the talking sub, tape pads, the smear, the grain cloud, the downpour, the stop bell, the notch Reese; hall, plate, and dub buses; scenes weather..last_word; the knob :variant (0 the first version, 1 the second) and the tracks' preset knobs; its flow (play_form doc.form).  `demo :n109` loads it."
knob :variant, (0.0..1.0).at(1.0)
knob :"vinyl/density", (1.0..200.0).at(14.0), description: "Specks per second"
knob :"sub/attack", (0.001..4.0).at(0.03), curve: :exp, description: "Amplitude attack in seconds (1.2: a swell)"
knob :"sub/cutoff", (100.0..2000.0).at(420.0), curve: :exp, description: "Lowpass cutoff in Hz"
knob :"sub_swell/cutoff", (100.0..2000.0).at(420.0), curve: :exp, description: "Lowpass cutoff in Hz"
knob :"pad/cutoff", (100.0..8000.0).at(900.0), curve: :exp, description: "lp4 cutoff in Hz"
knob :"pad/attack", (0.001..8.0).at(0.9), curve: :exp, description: "Attack in seconds"
knob :"pad/release", (0.01..10.0).at(1.4), curve: :exp, description: "Release in seconds"
knob :"pad_hi/cutoff", (100.0..8000.0).at(2200.0), curve: :exp, description: "lp4 cutoff in Hz"
knob :"pad_hi/attack", (0.001..8.0).at(1.2), curve: :exp, description: "Attack in seconds"
knob :"pad_hi/release", (0.01..10.0).at(1.6), curve: :exp, description: "Release in seconds"
knob :"reese/cutoff", (100.0..8000.0).at(800.0), curve: :exp, description: "lp4 cutoff in Hz (after the softclipper)"
knob :"reese/drive", (0.5..20.0).at(5.0), description: "Gain into the softclipper"
asset "assets/bounce.flac", sha256: "04b12c7001d515293f3a62c18ac82c82e1463542fe1c4388b9d879aeac568df2"
asset "assets/bounce_2.flac", sha256: "e28996df381dd50c49d30bc5ca79da51ea66bbc1a0e5f611241810b3a6f0a7fe"
asset "assets/bounce_3.flac", sha256: "047d1ccfaafa0815dc818506aef4e63b8d55b1c46ee627a8157f2c3452c5cc37"
asset "assets/bounce_4.flac", sha256: "7a9370ec920dc9ca1a1f28c668975aec4ea401cbf79e58f4c228823e8b60228b"
asset "assets/bounce_5.flac", sha256: "e089ec6b83451e5155e93dd8489e7d878687e9f5620aee85d17f13bcacbdff97"
asset "assets/bounce_6.flac", sha256: "f21644b4e9f2b486c07d79f4442a875bd2fc6af9a5f3898add9cf78dde893610"

bpm 174
bar = seq(Rest).n1.loop.named(:bar)
clicks = grid(16, rim: "5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|3.....2.....3...|3.....2...2.....|3.....2.....3...|3.....2...2.....|3.....2.....3...|3.....2...2.....|3.....2.....3...|3.....2...2.....|3.....2.....3...|3.....2...2.....|3.....2.....3...|3.....2...2.....|3.....2.....3...|3.....2...2.....|3.....2.....3...|3.....2...2.....|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|5..3..5..3..5.3.|5..3..5..3.5..3..|4.....3.....4...|4.....3.........|4.....3.....4...|4.....3.........|4.....3.....4...|4.....3.........|4.....3.....4...|4.....3.........|................|................").loop.named(:clicks)
chords = seq([F3, C4, Ds4, G4], Tie, [Fs3, As3, Cs4, F4], Tie).n1.loop(align: :launch).named(:chords)
chords_high = seq([F3, C4, Ds4, G4], Tie, [Fs3, As3, Cs4, F4], Tie).n1.transpose(12).loop(align: :launch).named(:chords_high)
smear = seq(C4, Tie, Tie, Tie, Tie, Tie, Tie, Tie).n1.loop(align: :launch).named(:smear)
reese_line = seq(F2, Tie, Tie, Tie, Tie, Tie, Tie, Tie, F2, Tie, Tie, Tie, Tie, Tie, Ds2, Tie, Fs2, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Fs2, Tie, Tie, Tie, Tie, Gs2, Tie, Rest).n8.loop(align: :launch).named(:reese_line)
bell_breakdown = seq(Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C6, Rest, G5, Rest, Rest, Rest, Gs5, Rest, Cs6, Rest, As5, Rest, Rest, F5, Rest, Rest, C6, Rest, G5, Rest, Rest, Rest, Gs5, Rest, Cs6, Rest, As5, Rest, Rest, F5, Rest, Rest, C6, Rest, G5, Rest, Rest, Rest, Gs5, Rest, Cs6, Rest, As5, Rest, Rest, F5, Rest).n4.loop(align: :launch).named(:bell_breakdown)
bell = seq(Rest, C6, Rest, G5, Rest, Rest, Rest, Gs5, Rest, Cs6, Rest, As5, Rest, Rest, F5, Rest).n4.loop(align: :launch).named(:bell)
vox_hats = seq(Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest).n16.loop(align: :launch).named(:vox_hats)
hats_hats = grid(16, hat: "x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...").loop(align: :launch).named(:hats_hats)
vox_kick = seq(Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest).n16.loop(align: :launch).named(:vox_kick)
drums_kick = grid(16, kick: "X.........x.....|X.........x.....|X.........x.....|X.........x.....|X.........x.....|X.........x.....|X.........x.....|X.........x.....", snare: "................|................|................|................|................|................|................|................", clap: "................|................|................|................|................|................|................|................").loop(align: :launch).named(:drums_kick)
hats_kick = grid(16, hat: "x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...").loop(align: :launch).named(:hats_kick)
shakers_kick = grid(16, open_hat: "..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.").loop(align: :launch).named(:shakers_kick)
vox_clack = seq(Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie).n16.loop(align: :launch).named(:vox_clack)
drums_clack = grid(16, kick: "X.........x.....|X.........x.....|X.........x.....|X.........x.....|X.........x.....|X.........x.....|X.........x.....|X...............", snare: "........X.......|........X.......|........X.......|........X.......|........X.......|........X.......|........X.......|........X.......", clap: "................|................|................|................|................|................|................|................").loop(align: :launch).named(:drums_clack)
hats_clack = grid(16, hat: "x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...").loop(align: :launch).named(:hats_clack)
shakers_clack = grid(16, open_hat: "..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.").loop(align: :launch).named(:shakers_clack)
vox_drop = seq(Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie).n16.loop(align: :launch).named(:vox_drop)
answer_drop = seq(Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C4, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, As3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C4, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, As3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C4, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, As3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C4, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest).n16.loop(align: :launch).named(:answer_drop)
drums_drop = grid(16, kick: "X.........x.....|X.....x...x..x..|X.........x.....|X..x......x...x.|X.........x.....|X.....x...x..x..|X.........x.....|X..x......x...x.|X.........x.....|X.....x...x..x..|X.........x.....|X..x......x...x.|X.........x.....|X.....x...x..x..|X.........x.....|X..x......x...x.|X.........x.....|X.....x...x..x..|X.........x.....|X..x......x...x.|X.........x.....|X.....x...x..x..|X.........x.....|X..x......x...x.|X.........x.....|X.....x...x..x..|X.........x.....|X..x......x...x.|X.........x.....|X.....x...x..x..|X.........x.....|X.....x.........", snare: "........X.......|........X.......|........X.......|........X..3....|........X.......|........X.......|........X.......|........X..3....|........X.......|........X.......|........X.......|........X..3....|........X.......|........X.......|........X.......|........X...3.5.|........X.......|........X.......|........X.......|........X..3....|........X.......|........X.......|........X.......|........X..3....|........X.......|........X.......|........X.......|........X..3....|........X.......|........X.......|........X.......|........X.......", clap: "................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................").loop(align: :launch).named(:drums_drop)
hats_drop = grid(16, hat: "x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...").loop(align: :launch).named(:hats_drop)
shakers_drop = grid(16, open_hat: "..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.").loop(align: :launch).named(:shakers_drop)
sub_drop = seq(F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Gs1, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Gs1, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Gs1, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Gs1, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Gs1, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Gs1, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Gs1, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest).n16.loop(align: :launch).named(:sub_drop)
vox_breakdown = seq(Rest, Rest, Rest, F3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest).n16.loop(align: :launch).named(:vox_breakdown)
drums_breakdown = grid(16, kick: "................|................|................|................|................|................|................|................|................|................|................|................|6...............|6...............|6...............|6...............", snare: "................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|..........3.4.6.", clap: "................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................").loop(align: :launch).named(:drums_breakdown)
swell_breakdown = seq(Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest).n16.loop(align: :launch).named(:swell_breakdown)
vox_drop2 = seq(Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Rest, C5, Rest, C5, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Rest, C5, Rest, C5, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Rest, C5, Rest, C5, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Rest, C5, Rest, C5, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Rest, C5, Rest, C5, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Rest, C5, Rest, C5, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Rest, C5, Rest, C5, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Rest, C5, Rest, C5, Tie, Tie, Rest).n16.loop(align: :launch).named(:vox_drop2)
drums_drop2 = grid(16, kick: "X.........x.....|X.........x.....|X.........x.....|X......x..x.....|X.........x.....|X.........x.....|X.........x.....|X......x..x.....|X.........x.....|X.........x.....|X.........x.....|X......x..x.....|X.........x.....|X.........x.....|X.........x.....|X......x..x.....", snare: "....X.......X...|....X.......X...|....X.......X...|....X.......X.4.|....X.......X...|....X.......X...|....X.......X...|....X.......X.4.|....X.......X...|....X.......X...|....X.......X...|....X.......X.4.|....X.......X...|....X.......X...|....X.......X...|....X.......X.X.", clap: "....X.......X...|....X.......X...|....X.......X...|....X.......X...|....X.......X...|....X.......X...|....X.......X...|....X.......X...|....X.......X...|....X.......X...|....X.......X...|....X.......X...|....X.......X...|....X.......X...|....X.......X...|....X.......X...").loop(align: :launch).named(:drums_drop2)
hats_drop2 = grid(16, hat: "x.6.x.6.x.6.x.6.|x.6.x.6.x.6.x.6.|x.6.x.6.x.6.x.6.|x.6.x.6.x.6.x.6.|x.6.x.6.x.6.x.6.|x.6.x.6.x.6.x.6.|x.6.x.6.x.6.x.6.|x.6.x.6.x.6.x.6.|x.6.x.6.x.6.x.6.|x.6.x.6.x.6.x.6.|x.6.x.6.x.6.x.6.|x.6.x.6.x.6.x.6.|x.6.x.6.x.6.x.6.|x.6.x.6.x.6.x.6.|x.6.x.6.x.6.x.6.|x.6.x.6.x.6.x.6.").loop(align: :launch).named(:hats_drop2)
shakers_drop2 = grid(16, open_hat: "..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.").loop(align: :launch).named(:shakers_drop2)
ride_drop2 = grid(16, ride: "6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.").loop(align: :launch).named(:ride_drop2)
sub_drop2 = seq(Rest, Rest, F1, Tie, Tie, Tie, Tie, Rest, F1, Tie, Rest, Rest, F1, Tie, Tie, Rest, Rest, Rest, F1, Tie, Tie, Tie, Gs1, Tie, Rest, Rest, Rest, Rest, F1, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Rest, Fs1, Tie, Rest, Rest, Fs1, Tie, Tie, Rest, Rest, Rest, Fs1, Tie, Tie, Tie, Gs1, Tie, Rest, Rest, Rest, Rest, Fs1, Tie, Tie, Rest, Rest, Rest, F1, Tie, Tie, Tie, Tie, Rest, F1, Tie, Rest, Rest, F1, Tie, Tie, Rest, Rest, Rest, F1, Tie, Tie, Tie, Gs1, Tie, Rest, Rest, Rest, Rest, F1, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Rest, Fs1, Tie, Rest, Rest, Fs1, Tie, Tie, Rest, Rest, Rest, Fs1, Tie, Tie, Tie, Gs1, Tie, Rest, Rest, Rest, Rest, Fs1, Tie, Tie, Rest, Rest, Rest, F1, Tie, Tie, Tie, Tie, Rest, F1, Tie, Rest, Rest, F1, Tie, Tie, Rest, Rest, Rest, F1, Tie, Tie, Tie, Gs1, Tie, Rest, Rest, Rest, Rest, F1, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Rest, Fs1, Tie, Rest, Rest, Fs1, Tie, Tie, Rest, Rest, Rest, Fs1, Tie, Tie, Tie, Gs1, Tie, Rest, Rest, Rest, Rest, Fs1, Tie, Tie, Rest, Rest, Rest, F1, Tie, Tie, Tie, Tie, Rest, F1, Tie, Rest, Rest, F1, Tie, Tie, Rest, Rest, Rest, F1, Tie, Tie, Tie, Gs1, Tie, Rest, Rest, Rest, Rest, F1, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Rest, Fs1, Tie, Rest, Rest, Fs1, Tie, Tie, Rest, Rest, Rest, Fs1, Tie, Tie, Tie, Gs1, Tie, Rest, Rest, Rest, Rest, Fs1, Tie, Tie, Rest).n16.loop(align: :launch).named(:sub_drop2)
vox_drop2b = seq(Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C5, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, F3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie).n16.loop(align: :launch).named(:vox_drop2b)
answer_drop2b = seq(Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C4, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, As3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C4, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, As3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C4, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, As3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, C4, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest).n16.loop(align: :launch).named(:answer_drop2b)
drums_drop2b = grid(16, kick: "X.........x.....|X.....x...x..x..|X.........x.....|X..x......x...x.|X.........x.....|X.....x...x..x..|X.........x.....|X..x......x...x.|X.........x.....|X.....x...x..x..|X.........x.....|X..x......x...x.|X.........x.....|X.....x...x..x..|X.........x.....|X..x............", snare: "........X.......|........X.......|........X.......|........X..3....|........X.......|........X.......|........X.......|........X..3....|........X.......|........X.......|........X.......|........X..3....|........X.......|........X.......|........X.......|........X.......", clap: "................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................").loop(align: :launch).named(:drums_drop2b)
hats_drop2b = grid(16, hat: "x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...").loop(align: :launch).named(:hats_drop2b)
shakers_drop2b = grid(16, open_hat: "..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.").loop(align: :launch).named(:shakers_drop2b)
ride_drop2b = grid(16, ride: "................|................|................|................|................|................|................|................|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.|6.x.6.x.6.x.6.x.").loop(align: :launch).named(:ride_drop2b)
sub_drop2b = seq(F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Gs1, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Gs1, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Gs1, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Fs1, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest).n16.loop(align: :launch).named(:sub_drop2b)
vox_outro = seq(Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F4, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, F3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest).n16.loop(align: :launch).named(:vox_outro)
drums_outro = grid(16, kick: "X.........x.....|X.....x...x..x..|X.........x.....|X..x......x...x.|X.........x.....|X.....x...x..x..|X.........x.....|X..x......x...x.|X.........x.....|X.....x...x..x..|X.........x.....|X..x......x...x.|X.........x.....|X.....x...x..x..|X.........x.....|X..x......x...x.", snare: "........X.......|........X.......|........X.......|........X.......|........X.......|........X.......|........X.......|........X.......|........X.......|........X.......|........X.......|........X.......|........X.......|........X.......|........X.......|........X.......", clap: "................|................|................|................|................|................|................|................|................|................|................|................|................|................|................|................").loop(align: :launch).named(:drums_outro)
hats_outro = grid(16, hat: "x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...").loop(align: :launch).named(:hats_outro)
shakers_outro = grid(16, open_hat: "..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.|..5...5...5...7.").loop(align: :launch).named(:shakers_outro)
drums_strip = grid(16, kick: "X.........x.....|X.........x.....|X.........x.....|X.........x.....|X.........x.....|X.........x.....|X.........x.....|X.........x.....", snare: "................|................|................|................|................|................|................|................", clap: "................|................|................|................|................|................|................|................").loop(align: :launch).named(:drums_strip)
hats_strip = grid(16, hat: "x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...").loop(align: :launch).named(:hats_strip)
hats_rain_out = grid(16, hat: "x...x...x...x...|x...x...x...x...|x...x...x...x...|x...x...x...x...").loop(align: :launch).named(:hats_rain_out)
vox_last_word = seq(Rest, Rest, Rest, F3, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Tie, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest, Rest).n16.loop(align: :launch).named(:vox_last_word)
master { |mix|
  (mix.mono_below(120) * 12.db).softclip(0.6, 0.94).limit(ceiling: -0.5.db)
}
bus(:hall) { |sig|
  sig.filter(:highpass, cutoff: 400).reverb(:hall, mix: 1)
}
bus(:plate) { |sig|
  sig.filter(:highpass, cutoff: 600).reverb(:plate, mix: 1)
}
bus(:dub) { |sig|
  sig.ping_pong(3.n16, feedback: 0.5).filter(:lowpass, cutoff: 2400).filter(:highpass, cutoff: 400)
}
bus(:rain_hall, to: :hall) { |sig|
  sig * (13.db ** variant * 1.0)
}
bus(:pour_hall, to: :hall) { |sig|
  sig * (9.db ** variant * 1.0)
}
bus(:rain_dub, to: :dub) { |sig|
  sig * variant ** 0.5
}
track(:rain, send: { rain_hall: -18.db, rain_dub: -12.db }) { |_c|
  sig = dust(160, range: 0.05..1, seed: 1)
  osc = noise(seed: drawn_seed(460313859063595327))
  osc2 = noise(seed: drawn_seed(3834957101560846777))
  sig2 = drift(1, seed: drawn_seed(2122851512282834192))
  ((sig.ping(osc.sample_hold(sig).at(2500..7000), decay: 0.02) * 0.12 + osc2.lp4(3000).at(-30.db)).pan(sig2) * (-3.db ** variant * 1.0)).at(1.db)
}
track(:vinyl) { |c|
  sig = dust(knob(:"vinyl/density"), bipolar: true, seed: drawn_seed(4096974857638661106))
  sig2 = dust(100, min_gap: 1800.ms, range: 0.6..1, seed: drawn_seed(1714963833883032382))
  (sig.filter(:bandpass, cutoff: 1400, quality: 0.7) * 0.6 + sig2.filter(:highpass, cutoff: 300) * 0.5).pan(-0.3).at(3.db)
}
track(:vox, send: { plate: -7.db, dub: -8.db }) { |c|
  voice = c.sampler(Sample["assets/bounce.flac"], seed: drawn_seed(3021027926230016238))
  voice2 = c.sampler(Sample["assets/bounce_2.flac"], seed: drawn_seed(1126427487768812950))
  (voice * (variant * -1 + 1) ** 0.5 + voice2 * variant ** 0.5).filter(:highpass, cutoff: 350).filter(:lowpass, cutoff: 4200).at(-14.db)
}
track(:answer, send: { plate: -5.db, dub: -10.db }) { |c|
  voice = c.sampler(Sample["assets/bounce_3.flac"], seed: drawn_seed(908964342104020660))
  voice2 = c.sampler(Sample["assets/bounce_4.flac"], seed: drawn_seed(4538682254840165685))
  (voice * (variant * -1 + 1) ** 0.5 + voice2 * variant ** 0.5).filter(:highpass, cutoff: 350).filter(:lowpass, cutoff: 4200).pan(0.3).at(-17.db)
}
track(:drums, send: { plate: -15.db }) { |c|
  kit(c, clap: { weight: 1.3333333333333333 ** variant * 0.45 }, seed: drawn_seed(3160828087365777864)) {
    voice(:kick, tune: 78) { |h|
      (h.body(h.tune, decay: 0.3, sweep: 2.6) * 1.3 + h.click(0.25)).filter(:highpass, cutoff: 70, quality: 0.7).softclip(0.6, 1.0)
    }
    # A clack more than a snare: woody FM knock, short noise, a bit of body.
    voice(:snare) { |h|
      (h.fm(820, ratio: 1.83, index: 3.0, decay: 0.07, index_decay: 0.02) * 0.7 +
        h.body(235, decay: 0.16, sweep: 1.4) * 0.8 +
        h.noise(decay: 0.22, highpass: 1500).filter(:lowpass, cutoff: 9000) * 0.5).softclip(0.5, 1.0)
    }
    # The weight that turns the clack into a snare when it goes two-step.
    voice(:clap, weight: 0.45) { |h|
      (h.body(196, decay: 0.24, sweep: 1.5) * 0.7 + h.noise(decay: 0.38, highpass: 1900).filter(:lowpass, cutoff: 10000) * 0.5).softclip(0.5, 1.0) * h.weight
    }
    voice(:rim) { |h| h.fm(1400, ratio: 2.41, index: 1.2, decay: 0.025, index_decay: 0.008) * 0.8 }
    voice(:hat, decay: 0.03) { |h| h.metal.filter(:highpass, cutoff: 9000).filter(:lowpass, cutoff: 13000) * h.env(h.decay) * 9 }
    voice(:open_hat, decay: 0.09) { |h| h.noise(decay: 0.09, highpass: 6000).filter(:lowpass, cutoff: 11000) * 0.5 }
    voice(:ride, decay: 0.2) { |h| h.metal.filter(:bandpass, cutoff: 6200, quality: 1.2) * h.env(h.decay) * 5 }
  }
}
track(:clicks, send: { plate: -14.db }) { |c|
  kit(c, clap: { weight: 1.3333333333333333 ** variant * 0.45 }, seed: drawn_seed(3736794927442007034)) {
    voice(:kick, tune: 78) { |h|
      (h.body(h.tune, decay: 0.3, sweep: 2.6) * 1.3 + h.click(0.25)).filter(:highpass, cutoff: 70, quality: 0.7).softclip(0.6, 1.0)
    }
    # A clack more than a snare: woody FM knock, short noise, a bit of body.
    voice(:snare) { |h|
      (h.fm(820, ratio: 1.83, index: 3.0, decay: 0.07, index_decay: 0.02) * 0.7 +
        h.body(235, decay: 0.16, sweep: 1.4) * 0.8 +
        h.noise(decay: 0.22, highpass: 1500).filter(:lowpass, cutoff: 9000) * 0.5).softclip(0.5, 1.0)
    }
    # The weight that turns the clack into a snare when it goes two-step.
    voice(:clap, weight: 0.45) { |h|
      (h.body(196, decay: 0.24, sweep: 1.5) * 0.7 + h.noise(decay: 0.38, highpass: 1900).filter(:lowpass, cutoff: 10000) * 0.5).softclip(0.5, 1.0) * h.weight
    }
    voice(:rim) { |h| h.fm(1400, ratio: 2.41, index: 1.2, decay: 0.025, index_decay: 0.008) * 0.8 }
    voice(:hat, decay: 0.03) { |h| h.metal.filter(:highpass, cutoff: 9000).filter(:lowpass, cutoff: 13000) * h.env(h.decay) * 9 }
    voice(:open_hat, decay: 0.09) { |h| h.noise(decay: 0.09, highpass: 6000).filter(:lowpass, cutoff: 11000) * 0.5 }
    voice(:ride, decay: 0.2) { |h| h.metal.filter(:bandpass, cutoff: 6200, quality: 1.2) * h.env(h.decay) * 5 }
  }.pan(0.25).at(8.db)
}
track(:hats) { |c|
  kit(c, clap: { weight: 1.3333333333333333 ** variant * 0.45 }, seed: drawn_seed(3122569074078764429)) {
    voice(:kick, tune: 78) { |h|
      (h.body(h.tune, decay: 0.3, sweep: 2.6) * 1.3 + h.click(0.25)).filter(:highpass, cutoff: 70, quality: 0.7).softclip(0.6, 1.0)
    }
    # A clack more than a snare: woody FM knock, short noise, a bit of body.
    voice(:snare) { |h|
      (h.fm(820, ratio: 1.83, index: 3.0, decay: 0.07, index_decay: 0.02) * 0.7 +
        h.body(235, decay: 0.16, sweep: 1.4) * 0.8 +
        h.noise(decay: 0.22, highpass: 1500).filter(:lowpass, cutoff: 9000) * 0.5).softclip(0.5, 1.0)
    }
    # The weight that turns the clack into a snare when it goes two-step.
    voice(:clap, weight: 0.45) { |h|
      (h.body(196, decay: 0.24, sweep: 1.5) * 0.7 + h.noise(decay: 0.38, highpass: 1900).filter(:lowpass, cutoff: 10000) * 0.5).softclip(0.5, 1.0) * h.weight
    }
    voice(:rim) { |h| h.fm(1400, ratio: 2.41, index: 1.2, decay: 0.025, index_decay: 0.008) * 0.8 }
    voice(:hat, decay: 0.03) { |h| h.metal.filter(:highpass, cutoff: 9000).filter(:lowpass, cutoff: 13000) * h.env(h.decay) * 9 }
    voice(:open_hat, decay: 0.09) { |h| h.noise(decay: 0.09, highpass: 6000).filter(:lowpass, cutoff: 11000) * 0.5 }
    voice(:ride, decay: 0.2) { |h| h.metal.filter(:bandpass, cutoff: 6200, quality: 1.2) * h.env(h.decay) * 5 }
  }
}
track(:shakers) { |c|
  kit(c, clap: { weight: 1.3333333333333333 ** variant * 0.45 }, seed: drawn_seed(763495637846601995)) {
    voice(:kick, tune: 78) { |h|
      (h.body(h.tune, decay: 0.3, sweep: 2.6) * 1.3 + h.click(0.25)).filter(:highpass, cutoff: 70, quality: 0.7).softclip(0.6, 1.0)
    }
    # A clack more than a snare: woody FM knock, short noise, a bit of body.
    voice(:snare) { |h|
      (h.fm(820, ratio: 1.83, index: 3.0, decay: 0.07, index_decay: 0.02) * 0.7 +
        h.body(235, decay: 0.16, sweep: 1.4) * 0.8 +
        h.noise(decay: 0.22, highpass: 1500).filter(:lowpass, cutoff: 9000) * 0.5).softclip(0.5, 1.0)
    }
    # The weight that turns the clack into a snare when it goes two-step.
    voice(:clap, weight: 0.45) { |h|
      (h.body(196, decay: 0.24, sweep: 1.5) * 0.7 + h.noise(decay: 0.38, highpass: 1900).filter(:lowpass, cutoff: 10000) * 0.5).softclip(0.5, 1.0) * h.weight
    }
    voice(:rim) { |h| h.fm(1400, ratio: 2.41, index: 1.2, decay: 0.025, index_decay: 0.008) * 0.8 }
    voice(:hat, decay: 0.03) { |h| h.metal.filter(:highpass, cutoff: 9000).filter(:lowpass, cutoff: 13000) * h.env(h.decay) * 9 }
    voice(:open_hat, decay: 0.09) { |h| h.noise(decay: 0.09, highpass: 6000).filter(:lowpass, cutoff: 11000) * 0.5 }
    voice(:ride, decay: 0.2) { |h| h.metal.filter(:bandpass, cutoff: 6200, quality: 1.2) * h.env(h.decay) * 5 }
  }.delay(0.021).pan(-0.2).at(7.db)
}
track(:ride) { |c|
  kit(c, clap: { weight: 1.3333333333333333 ** variant * 0.45 }, seed: drawn_seed(1114563448603701044)) {
    voice(:kick, tune: 78) { |h|
      (h.body(h.tune, decay: 0.3, sweep: 2.6) * 1.3 + h.click(0.25)).filter(:highpass, cutoff: 70, quality: 0.7).softclip(0.6, 1.0)
    }
    # A clack more than a snare: woody FM knock, short noise, a bit of body.
    voice(:snare) { |h|
      (h.fm(820, ratio: 1.83, index: 3.0, decay: 0.07, index_decay: 0.02) * 0.7 +
        h.body(235, decay: 0.16, sweep: 1.4) * 0.8 +
        h.noise(decay: 0.22, highpass: 1500).filter(:lowpass, cutoff: 9000) * 0.5).softclip(0.5, 1.0)
    }
    # The weight that turns the clack into a snare when it goes two-step.
    voice(:clap, weight: 0.45) { |h|
      (h.body(196, decay: 0.24, sweep: 1.5) * 0.7 + h.noise(decay: 0.38, highpass: 1900).filter(:lowpass, cutoff: 10000) * 0.5).softclip(0.5, 1.0) * h.weight
    }
    voice(:rim) { |h| h.fm(1400, ratio: 2.41, index: 1.2, decay: 0.025, index_decay: 0.008) * 0.8 }
    voice(:hat, decay: 0.03) { |h| h.metal.filter(:highpass, cutoff: 9000).filter(:lowpass, cutoff: 13000) * h.env(h.decay) * 9 }
    voice(:open_hat, decay: 0.09) { |h| h.noise(decay: 0.09, highpass: 6000).filter(:lowpass, cutoff: 11000) * 0.5 }
    voice(:ride, decay: 0.2) { |h| h.metal.filter(:bandpass, cutoff: 6200, quality: 1.2) * h.env(h.decay) * 5 }
  }.duck(:drums, amount: -7.db, release: 1.n16).pan(0.15).at(-3.db)
}
track(:sub) { |c|
  lfo = 4.bars.hz.lfo.at(0.1..1.0)
  synth(c, voices: 1) { |v|
    f = v.hz.glide(60.ms)
    grunt = v.env(0.004, 0.22, 0.3, 0.05)
    f.fm(f.transpose(19.019550008653873).at(90) * grunt + f.transpose(24).at(150) * lfo * grunt) * v.amp_env(knob(:"sub/attack"), 0.1, 1.0, 0.1)
  }.filter(:lowpass, cutoff: knob(:"sub/cutoff")).duck(:drums, only: :kick, amount: -9.db, release: 1.n32).at(-2.db)
}
track(:sub_swell) { |c|
  lfo = 4.bars.hz.lfo.at(0.1..1.0)
  synth(c, voices: 1) { |v|
    f = v.hz.glide(60.ms)
    grunt = v.env(0.004, 0.22, 0.3, 0.05)
    f.fm(f.transpose(19.019550008653873).at(90) * grunt + f.transpose(24).at(150) * lfo * grunt) * v.amp_env(1.2.constant.named("attack"), 0.1, 1.0, 0.1)
  }.filter(:lowpass, cutoff: knob(:"sub_swell/cutoff")).at(-9.db)
}
track(:pad, send: { hall: -8.db }) { |c|
  voice = synth(c, voices: 8) { |v|
    sig = v.hz
    (sig.saw + sig.transpose(-0.12).saw + sig.transpose(12.05).triangle * 0.4).lp4(knob(:"pad/cutoff"), resonance: 0.1) * v.amp_env(knob(:"pad/attack"), 0.5, 0.85, knob(:"pad/release"))
  }
  sig = drift(0.8, smooth: :cosine, seed: drawn_seed(1121518053200921046))
  voice.delay(sig.at(0.004..0.008) + 6.hz.lfo.at(0.0001)).filter(:highpass, cutoff: 180).chorus.at(-22.db)
}
track(:vox_cloud, send: { hall: -6.db }) { |_c|
  sig = Sample["assets/bounce.flac"].grains(size: 140.ms, density: 14, pitch: [0, 7, 12], pan_spread: 0.9, seed: drawn_seed(1689715129981764354))
  sig2 = Sample["assets/bounce_2.flac"].grains(size: 140.ms, density: 14, pitch: [0, 7, 12], pan_spread: 0.9, seed: drawn_seed(413158123587211532))
  (sig * (variant * -1 + 1) ** 0.5 + sig2 * variant ** 0.5).filter(:highpass, cutoff: 500).at(-21.db)
}
track(:smear, send: { hall: -6.db }) { |c|
  voice = c.sampler(Sample["assets/bounce_5.flac"], seed: drawn_seed(1494514125730346901))
  voice2 = c.sampler(Sample["assets/bounce_6.flac"], seed: drawn_seed(1921507198441152297))
  (voice * (variant * -1 + 1) ** 0.5 + voice2 * variant ** 0.5).filter(:highpass, cutoff: 300).filter(:lowpass, cutoff: 5000).chorus.at(-20.db)
}
track(:pad_hi, send: { hall: -6.db }) { |c|
  voice = synth(c, voices: 8) { |v|
    sig = v.hz
    (sig.triangle + sig.transpose(0.1).saw * 0.3).lp4(knob(:"pad_hi/cutoff"), resonance: 0.1) * v.amp_env(knob(:"pad_hi/attack"), 0.5, 0.8, knob(:"pad_hi/release"))
  }
  sig = drift(0.8, smooth: :cosine, seed: drawn_seed(1196539196237746438))
  voice.delay(sig.at(0.004..0.008) + 6.hz.lfo.at(0.0001)).chorus.at(-27.db)
}
track(:downpour, send: { pour_hall: -14.db, rain_dub: -12.db }) { |_c|
  sig = dust(260, range: 0.05..1, seed: 7)
  osc = noise(seed: drawn_seed(3573808634927103112))
  sig2 = drift(0.7, seed: drawn_seed(4444286953195003224))
  ((sig.ping(osc.sample_hold(sig).at(2000..8000), decay: 0.02) * 0.12).pan(sig2) * (-3.db ** variant * 1.0)).at(-2.db)
}
track(:bell, send: { hall: -5.db, dub: -7.db }) { |c|
  struck(c, :rin, voices: 4, level: 1).filter(:highpass, cutoff: 400).pan(-0.25).at(-15.db)
}
track(:reese, send: { hall: -14.db }) { |c|
  (synth(c, voices: 1) { |v|
    f = v.hz.glide(60.ms)
    (f.transpose(-0.09).saw + f.transpose(0.09).saw + f.transpose(12.04).saw * 0.3) * v.amp_env(0.06, 0.2, 0.9, 0.2)
  } * knob(:"reese/drive")).softclip(0.25, 0.8).lp4(knob(:"reese/cutoff"), resonance: 0.18).filter(:highpass, cutoff: 120).filter(:highpass, cutoff: 120).filter(:notch, cutoff: 3.bars.hz.lfo.at(500..1400), quality: 1.6).duck(:drums, amount: -4.db, release: 1.n16).at(-7.db)
}
scene :weather, rain: bar, vinyl: { clip: bar, level: 1 }, clicks: clicks
scene :hats, rain: bar, vinyl: { clip: bar, level: 1 }, vox: vox_hats, clicks: clicks, hats: hats_hats, pad: { clip: chords, level: 1 }, vox_cloud: { clip: bar, level: 1 }
scene :kick, rain: bar, vinyl: { clip: bar, level: 1 }, vox: vox_kick, drums: drums_kick, clicks: clicks, hats: hats_kick, shakers: shakers_kick, pad: { clip: chords, level: 1 }, vox_cloud: { clip: bar, level: 1 }
scene :clack, rain: bar, vinyl: { clip: bar, level: 1 }, vox: vox_clack, drums: drums_clack, clicks: clicks, hats: hats_clack, shakers: shakers_clack, pad: { clip: chords, level: 1 }, vox_cloud: { clip: bar, level: 1 }
scene :drop, rain: bar, vinyl: { clip: bar, level: 1 }, vox: vox_drop, answer: answer_drop, drums: drums_drop, clicks: clicks, hats: hats_drop, shakers: shakers_drop, sub: sub_drop, pad: { clip: chords, level: 1 }, vox_cloud: { clip: bar, level: 1 }
scene :breakdown, rain: bar, vinyl: { clip: bar, level: 1 }, vox: vox_breakdown, drums: drums_breakdown, clicks: clicks, sub_swell: swell_breakdown, pad: { clip: chords, level: 1 }, vox_cloud: { clip: bar, level: 1 }, smear: smear, pad_hi: { clip: chords_high, level: 1 }, downpour: bar, bell: bell_breakdown
scene :drop2, rain: bar, vinyl: { clip: bar, level: 1 }, vox: vox_drop2, drums: drums_drop2, clicks: clicks, hats: hats_drop2, shakers: shakers_drop2, ride: ride_drop2, sub: sub_drop2, pad: { clip: chords, level: 1 }, vox_cloud: { clip: bar, level: 1 }, smear: :cut, downpour: :cut, pad_hi: { level: [0, { over: 2, curve: :sine_in }] }
scene :drop2b, rain: bar, vinyl: { clip: bar, level: 1 }, vox: vox_drop2b, answer: answer_drop2b, drums: drums_drop2b, clicks: clicks, hats: hats_drop2b, shakers: shakers_drop2b, ride: ride_drop2b, sub: sub_drop2b, pad: { clip: chords, level: 1 }, vox_cloud: { clip: bar, level: 1 }, reese: { clip: reese_line, level: 1, cutoff: [1300, { from: 420, over: 16 }] }
scene :outro, rain: bar, vinyl: { clip: bar, level: 1 }, vox: vox_outro, drums: drums_outro, clicks: clicks, hats: hats_outro, shakers: shakers_outro, pad: { clip: chords, level: 1 }, vox_cloud: { clip: bar, level: 1 }, reese: { level: [0, { over: 1, curve: :sine_in }] }
scene :strip, rain: bar, vinyl: { clip: bar, level: 1 }, drums: drums_strip, clicks: clicks, hats: hats_strip, bell: bell, pad: { level: [0, { over: 8, curve: :sine_in }] }, vox_cloud: { level: [0, { over: 12, curve: :sine_in }] }
scene :rain_out, rain: bar, vinyl: { clip: bar, level: 1 }, clicks: clicks, hats: hats_rain_out, vox_cloud: :keep
scene :last_word, rain: bar, vinyl: { level: [0, { over: 4, curve: :sine_in }] }, vox: vox_last_word, clicks: clicks
flow do
  weather 8
  hats 8
  kick 8
  clack 8
  drop 32
  breakdown 16
  drop2 16
  drop2b 16
  outro 16
  strip 8
  rain_out 4
  last_word 6
end
