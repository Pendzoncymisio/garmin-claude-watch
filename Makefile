# claudeWatch — CLI build. This file is the source of truth; VS Code is optional.
#
# Requires the Connect IQ SDK on PATH:
#   export PATH=$PATH:$(cat $HOME/.Garmin/ConnectIQ/current-sdk.cfg)/bin

DEVICE  := fenix8pro47mm
NAME    := claudeWatch
BIN     := bin
KEY     := developer_key.der
JUNGLE  := monkey.jungle

MONKEYC := monkeyc
MONKEYDO:= monkeydo

# The simulator links against libjpeg.so.8, which current Debian/Parrot no longer
# ships (it has libjpeg.so.62 — a different ABI, so symlinking is not safe).
# A copy extracted from the Ubuntu libjpeg-turbo8 package lives in ~/.local/lib.
# Compilation does not need this; only the simulator does.
# SSL_CERT_FILE points the simulator's bundled OpenSSL at the dev CA bundle
# (system roots + server/scripts/make-dev-certs.sh CA), so it will trust the
# local HTTPS server. Connect IQ rejects plain http with -1001 even in the
# simulator, so there is no way to test the round trip without this.
SIM_ENV := LD_LIBRARY_PATH=$(HOME)/.local/lib:$$LD_LIBRARY_PATH \
           SSL_CERT_FILE=$(CURDIR)/server/certs/bundle.pem

.PHONY: all build run sim test package clean key check-sdk

all: build

check-sdk:
	@command -v $(MONKEYC) >/dev/null 2>&1 || { \
	  echo "monkeyc not on PATH. Run:"; \
	  echo '  export PATH=$$PATH:$$(cat $$HOME/.Garmin/ConnectIQ/current-sdk.cfg)/bin'; \
	  exit 1; }

# Headless — never needs a display.
build: check-sdk $(KEY)
	@mkdir -p $(BIN)
	$(MONKEYC) -d $(DEVICE) -f $(JUNGLE) -o $(BIN)/$(NAME).prg -y $(KEY) --typecheck 3 --warn

# Needs the GUI simulator, which must already be running — start it with `make sim`
# (or plain `connectiq`) in another shell first.
run: build
	$(SIM_ENV) $(MONKEYDO) $(BIN)/$(NAME).prg $(DEVICE)

# Start the simulator itself. Long-running; leave it up across builds.
sim:
	$(SIM_ENV) connectiq

# Unit tests run ONLY inside the simulator; there is no headless test path.
test: build
	$(SIM_ENV) $(MONKEYDO) $(BIN)/$(NAME).prg $(DEVICE) -t

# .iq package for upload to apps-developer.garmin.com (beta or production).
package: check-sdk $(KEY)
	@mkdir -p $(BIN)
	$(MONKEYC) -e -f $(JUNGLE) -o $(BIN)/$(NAME).iq -y $(KEY) --typecheck 3 --warn

$(KEY):
	@echo "No $(KEY) — generating a developer key (keep it out of version control)."
	openssl genrsa -out developer_key.pem 4096
	openssl pkcs8 -topk8 -inform PEM -outform DER \
	    -in developer_key.pem -out $(KEY) -nocrypt

key: $(KEY)

clean:
	rm -rf $(BIN)
