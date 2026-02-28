FROM docker.io/library/ruby:3.4

ARG DEBIAN_FRONTEND=none
RUN apt-get -y update && apt-get -y upgrade && apt-get -y --no-install-recommends install libsamplerate-dev libjack-dev build-essential gnuplot bash-completion git pkgconf

COPY .bash_aliases /root/.bash_aliases
RUN echo 'export PATH="/root/.local/bin:$PATH"' >> /root/.bashrc && echo 'source ~/.bash_aliases' >> /root/.bashrc && echo "PS1='\\[\\033[01;32m\\]\\u@\\h\\[\\033[00m\\] \\[\\033[01;36m\\]\\w \\[\\033[01m\\]\\$\\[\\033[0m\\] '" >> /root/.bashrc

RUN mkdir /mb-sound
RUN --mount=type=bind,source=.,destination=/mb-sound cd /mb-sound && bundle install

VOLUME /mb-sound

WORKDIR /
RUN curl -fsSL https://claude.ai/install.sh | bash

WORKDIR /mb-sound
CMD /bin/bash
