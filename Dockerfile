FROM docker.io/library/ruby:3.4

ENV DEBIAN_FRONTEND=none
RUN apt-get -y update && apt-get -y upgrade && apt-get -y --no-install-recommends install libsamplerate-dev libjack-dev build-essential gnuplot bash-completion git pkgconf

RUN mkdir /mb-sound
WORKDIR /mb-sound
VOLUME /mb-sound

RUN --mount=type=bind,source=.,destination=/mb-sound,ro bundle install && rake clean compile

RUN curl -fsSL https://claude.ai/install.sh | bash

COPY .bash_aliases /root/.bash_aliases
RUN echo 'export PATH="$HOME/.local/bin:$PATH"' >> /root/.bashrc && echo 'source ~/.bash_aliases' >> /root/.bashrc && echo "PS1='\[\033[01;32m\]\u@\h\[\033[00m\] \[\033[01;36m\]\w \[\033[01m\]\$\[\033[0m\] '" >> /root/.bashrc

CMD /bin/bash
