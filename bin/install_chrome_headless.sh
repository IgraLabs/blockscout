export DISPLAY=:99.0
sh -e /etc/init.d/xvfb start

# Install Chrome FIRST, then match chromedriver to the Chrome that actually landed.
#
# This used to pin CHROMEDRIVER_VERSION to a literal while installing
# `google-chrome-stable_current`, i.e. a fixed driver against a floating browser.
# That drifts silently and then breaks all at once: when Chrome stable rolled
# 152 -> 153, chromedriver 150 refused every session and all Wallaby feature
# tests died in setup with `(RuntimeError) invalid session id` -- not in the test
# bodies, so the failures looked unrelated to the browser.
wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
sudo apt-get update
sudo apt-get install libstdc++6
sudo apt install ./google-chrome-stable_current_amd64.deb

CHROME_MAJOR=$(google-chrome --version | grep -oE '[0-9]+' | head -1)
if [ -z "${CHROME_MAJOR}" ]; then
  echo "Could not determine installed Chrome version" >&2
  exit 1
fi

# Chromedriver is compatible within a major version, so match on milestone.
CHROMEDRIVER_VERSION=$(curl -s "https://googlechromelabs.github.io/chrome-for-testing/latest-versions-per-milestone.json" \
  | jq -r ".milestones[\"${CHROME_MAJOR}\"].version")
if [ -z "${CHROMEDRIVER_VERSION}" ] || [ "${CHROMEDRIVER_VERSION}" = "null" ]; then
  echo "No chromedriver published for Chrome milestone ${CHROME_MAJOR}" >&2
  exit 1
fi
export CHROMEDRIVER_VERSION

echo "Chrome ${CHROME_MAJOR} -> chromedriver ${CHROMEDRIVER_VERSION}"
curl -fL -O "https://edgedl.me.gvt1.com/edgedl/chrome/chrome-for-testing/${CHROMEDRIVER_VERSION}/linux64/chromedriver-linux64.zip"
unzip -o -j chromedriver-linux64.zip chromedriver
sudo chmod +x chromedriver
sudo mv chromedriver /usr/local/bin

# Fail the step here rather than 38 tests later in Wallaby setup.
chromedriver --version
