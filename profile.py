"""CloudLab profile: automatic KIND cluster + KServe LLMInferenceService setup.

CloudLab automatically clones this repo to /local/repository on every node
before the startup command runs, so there is no git clone step needed.

Instructions:
Wait for the profile instance to start. The KIND cluster will already be setup or be in the setup phase. Check setup progress after SSH-ing in:

    tail -f /var/log/kserve-setup.log
    cat  /var/log/kserve-setup.status

"""

import geni.portal as portal
import geni.rspec.pg as rspec

pc = portal.Context()

pc.defineParameter(
    "nodeType",
    "Node Hardware Type",
    portal.ParameterType.STRING,
    "c220g2",
    [
        ("c220g2", "c220g2 (Wisc) - 2x10-core E5-2660v3, 160 GB RAM, 2x480 GB SSD"),
        ("c220g5", "c220g5 (Wisc) - 2x20-core Gold 6148,  384 GB RAM, 2x960 GB SSD"),
    ],
)

pc.defineParameter(
    "run_setup",
    "Auto-run setup on boot?",
    portal.ParameterType.BOOLEAN,
    True,
    longDescription=(
        "If True, scripts/cloudlab_setup.sh runs unattended on first boot. "
        "Set False to SSH in and run scripts yourself."
    ),
)

params = pc.bindParameters()
pc.verifyParameters()

request = pc.makeRequestRSpec()

node = request.RawPC("node0")
node.hardware_type = params.nodeType
node.disk_image = "urn:publicid:IDN+emulab.net+image+emulab-ops:UBUNTU24-64-STD"

# /local/repository is where CloudLab clones the profile repo automatically.
# We background the setup so the node is marked ready immediately and you
# can SSH in to watch progress via the log.
_repo_dir = "/local/repository"
_cmd = "true"  # no-op if run_setup=False

if params.run_setup:
    _cmd = (
        "bash {repo}/startup.sh"
        " >> /var/log/kserve-setup.log 2>&1"
    ).format(repo=_repo_dir)

node.addService(rspec.Execute(shell="bash", command=f"( {_cmd} ) &"))

pc.printRequestRSpec(request)
