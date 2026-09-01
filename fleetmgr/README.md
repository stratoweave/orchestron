# fleetmgr — minimal fleet manager

A StratoWeave app just functional enough to build a web UI against:
device inventory plus software upgrade campaigns, with mock CPEs behind
it. The logic is deliberately naive; the northbound YANG is the contract,
so the machinery behind it can be replaced without the UI noticing.

    just gen                                 # regenerate after YANG changes
    acton build
    out/bin/fleetmgr --http-port 18200 --netconf-port 12900 demo.xml

demo.xml seeds 20 CPEs at startup so there is a fleet to play with;
leave it off to start empty.

## The UI contract

The app-specific `fleetmgr` model owns device inventory and connection
settings. The reusable `software` model owns campaigns and their progress.
Config is written with PATCH, and progress is read from config-false `state`
under each campaign.

Create devices and a campaign (campaigns start in `plan`: declared,
inspectable, doing nothing):

    curl -X PATCH -H "Content-Type: application/yang-data+json" \
      --data-binary '{
        "fleetmgr:fleet": {"device": [
          {"name": "cpe-1", "credentials": {
             "username": "admin", "password": "admin"},
           "mock": {"enabled": true}},
          {"name": "cpe-2", "credentials": {
             "username": "admin", "password": "admin"},
           "mock": {"enabled": true}}]},
        "software:software": {"upgrade-campaign": [
          {"name": "xe-upgrade", "target-release": "17.18.03a",
           "device": ["cpe-1", "cpe-2"], "admin-state": "plan"}]}}' \
      http://127.0.0.1:18200/restconf/data

Launch it:

    curl -X PATCH -H "Content-Type: application/yang-data+json" \
      --data-binary '{"software:software": {"upgrade-campaign": [
        {"name": "xe-upgrade", "admin-state": "run"}]}}' \
      http://127.0.0.1:18200/restconf/data

Poll progress (GET /restconf/data merges oper state):

    "state": {
      "total": 2, "in-progress": 0, "succeeded": 2, "failed": 0,
      "device-status": [
        {"device": "cpe-1", "status": "succeeded"},
        {"device": "cpe-2", "status": "succeeded"}]}

## How it hangs together

    campaign (run)  --CFS Campaign transform---> device software target
    device          --CFS Device transform-----> device entry (mock)
    SoftwareManager --pushes status------------> device/software/state oper
    campaign actor  --subscribes device state--> campaign state counts

Two CFS transforms write the same device entry (Device the base fields,
Campaign the software container); TTT merges them. The device entry
publishes its SoftwareManager's status itself (stratoweave core), so the
app carries no status-publishing machinery of its own.

## Deliberately naive

- Installs are MockSoftwareAdapter and always succeed; here they take a
  random 1-4s each so progress is visible. Everywhere else the mock
  defaults to instant, which is what the tests want.
- The campaign's subscription samples device state once a second.
- No maintenance windows, scheduling, waves, vetoes or redundancy
  constraints -- the campaign fires everything at once on `run`.
- No plan preview, no pause/abort, no campaign completion latching:
  status reflects the devices' current SoftwareManager state.
- Devices are mock CPEs declared northbound; no real inventory.
