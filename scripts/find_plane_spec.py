import sys
import json
import os

# Add the MCP server directory to path to import CLIENT and STATE
sys.path.append("/Users/superudmarts/Desktop/cluely/BetterSiri/Sources/Resources/OnShapeAgent")
from onshape_mcp_server import CLIENT, STATE, _parse_onshape_url

# Setup credentials from env if not already there
# Actually they should be in the STATE already if we were running in the app, 
# but here we need to initialize CLIENT manually or hope it picks up env.

def find_plane_spec():
    did = "89a3e2e598f9ad2ace0fb496"
    wid = "8c522fba543883263f4d1645"
    
    # List elements to find a valid PS
    elements = CLIENT.list_elements(did, "w", wid)
    eid = None
    if isinstance(elements, list):
        for el in elements:
            if el.get("elementType") == "PARTSTUDIO":
                eid = el.get("id")
                break
    
    if not eid:
        print("No Part Studio found")
        return

    print(f"Using eid: {eid}")
    specs = CLIENT.get_partstudio_featurespecs(did, "w", wid, eid)
    if isinstance(specs, dict) and "featureSpecs" in specs:
        for s in specs["featureSpecs"]:
            if "plane" in s.get("featureType", "").lower():
                print(json.dumps(s, indent=2))
                return
    print("Plane spec not found")

if __name__ == "__main__":
    # Mocking environment for the script
    os.environ["ONSHAPE_BASE_URL"] = "https://cad.onshape.com/api"
    CLIENT.access_token = "6BCqdB3prUW37dccC+HkuA=="
    CLIENT.auth_mode = "oauth"
    find_plane_spec()
