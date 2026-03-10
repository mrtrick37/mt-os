# Kyth 43 — Anaconda WebUI kickstart
# Pulled into the live initramfs at /run/install/ks.cfg by dracut --include.
# Anaconda reads this automatically via inst.ks=file:///run/install/ks.cfg.

ostreecontainer --url="ghcr.io/mrtrick37/kyth:latest" --no-signature-verification

clearpart --all --initlabel
autopart --type=plain

%packages
%end
