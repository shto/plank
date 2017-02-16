# Base image from Swiftenv with Swift version 3.0.1
FROM kylef/swiftenv
MAINTAINER Pinterest
RUN swiftenv install 3.0.1

# Vim config so we have an editor available
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        vim clang libicu-dev libcurl4-openssl-dev libssl-dev unzip

# Install SwiftLint
ENV SWIFT_LINT_VERSION 0.16.1
ENV SWIFT_LINT_SHA 85abab13b94d569ba7d85ee28dbf1d35cb606b0d
#ADD https://github.com/realm/SwiftLint/releases/download/${SWIFT_LINT_VERSION}/portable_swiftlint.zip /usr/local/bin
ADD https://github.com/realm/SwiftLint/archive/${SWIFT_LINT_SHA}.zip \
    /usr/local/bin
RUN \
	unzip /usr/local/bin/${SWIFT_LINT_SHA}.zip -d /usr/local/bin && \
    cd /usr/local/bin/SwiftLint-${SWIFT_LINT_SHA} &&  \
    swift build -c release && \
    cp .build/release/swiftlint /usr/local/bin && \
	chmod 755 /usr/local/bin/swiftlint

# Install plank
ENV PLANK_HOME /usr/local/plank
COPY . ${PLANK_HOME}
RUN cd ${PLANK_HOME} && swift build -c release

ENV PATH ${PLANK_HOME}/.build/release:${PATH}

#ENTRYPOINT ["plank"]
#CMD ["help"]
