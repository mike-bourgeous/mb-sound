require 'mb/term'

module MB
  module Sound
    module UI
      # The terminal UI's generic layers live in the mb-term gem
      # (gems/mb-term, MB::Term).  These names keep the mb-sound side's
      # references working while other branches still use them; a follow-up
      # migrates the callers and removes them (term-extract-1).
      VT = MB::Term::VT
      Term = MB::Term::Terminal
      Screen = MB::Term::Screen
      Input = MB::Term::Input
      Viewports = MB::Term::Viewports
      Themes = MB::Term::Themes
      DataFile = MB::Term::DataFile
    end
  end
end
