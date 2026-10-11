# mb-sound plots with MB::Sound::Plot (pure Ruby); nothing in the library
# should start mb-math's gnuplot-backed MB::M::Plot any more (its output
# race once made plot specs flaky).  Fails any spec that does.
module NoGnuplot
  def initialize(*)
    raise 'MB::M::Plot (gnuplot) was started; use MB::Sound::Plot (e.g. MB::Sound.plotter or MB::Sound::Plot::Plotter)'
  end
end

MB::M::Plot.prepend(NoGnuplot) if defined?(MB::M::Plot)
