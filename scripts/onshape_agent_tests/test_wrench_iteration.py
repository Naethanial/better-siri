#!/usr/bin/env python3
"""
Iterative wrench-creation test using FeatureScript.

This script will:
1. Set context to the test document
2. Attempt to create a wrench via FeatureScript
3. Validate the result (bounding box / features)
4. Clean up (delete created features)
5. Print diagnostics for iteration
"""

import os
import sys
import json
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from scripts.onshape_agent_tests._bootstrap import ensure_onshape_agent_on_path, ensure_onshape_oauth_env

DEFAULT_TEST_URL = (
    "https://cteinccsd.onshape.com/documents/89a3e2e598f9ad2ace0fb496/"
    "w/8c522fba543883263f4d1645/e/466338a94d244e8b3d9ca656"
)


def _ensure_env() -> None:
    ensure_onshape_oauth_env()


def _extract_feature_id(resp):
    if not isinstance(resp, dict):
        return None
    feature = resp.get("feature")
    if isinstance(feature, dict) and isinstance(feature.get("featureId"), str):
        return feature.get("featureId")
    if isinstance(resp.get("featureId"), str):
        return resp.get("featureId")
    return None


def setup_context(m, url):
    """Parse URL and set context."""
    parsed = m.tool_onshape_parse_url({"url": url})
    if not isinstance(parsed, dict) or parsed.get("error"):
        raise RuntimeError(f"Failed to parse test URL: {parsed}")

    ctx = m.tool_onshape_set_context({
        "did": parsed.get("did"),
        "wvm": parsed.get("wvm"),
        "wvmid": parsed.get("wvmid"),
        "eid": parsed.get("eid"),
        "base_url": parsed.get("base_url"),
    })
    print(f"Context: did={ctx['did']}, wvm={ctx['wvm']}, wvmid={ctx['wvmid']}, eid={ctx['eid']}")
    return ctx


def get_current_features(m):
    """Get summary of current features."""
    result = m.tool_onshape_get_features_summary({})
    if isinstance(result, dict) and result.get("error"):
        print(f"Warning: Could not get features: {result}")
        return []
    return result.get("features", [])


def cleanup_features(m, feature_ids):
    """Delete features by ID."""
    wid = m.STATE.wvmid if m.STATE.wvm == "w" else None
    eid = m.STATE.eid
    did = m.STATE.did
    
    for fid in reversed(feature_ids):
        try:
            m.tool_onshape_delete_partstudio_feature({
                "did": did, "wid": wid, "eid": eid, "feature_id": fid
            })
            print(f"  Deleted feature {fid}")
        except Exception as e:
            print(f"  Failed to delete {fid}: {e}")


def attempt_wrench_featurescript_v1(m):
    """
    Attempt 1: Simple FeatureScript that creates a basic wrench shape.
    
    This uses opExtrude with a sketch-like profile.
    """
    
    script = '''
function(context is Context, queries is map)
{
    // Create a simple wrench profile on the XY plane (Top)
    var sketchPlane = plane(vector(0, 0, 0) * meter, vector(0, 0, 1));
    
    // Wrench parameters
    var handleLength = 150 * millimeter;
    var handleWidth = 20 * millimeter;
    var headRadius = 25 * millimeter;
    var jawOpening = 15 * millimeter;
    var thickness = 5 * millimeter;
    
    // Create sketch
    var sketch1 = newSketchOnPlane(context, id + "sketch1", { "sketchPlane" : sketchPlane });
    
    // Draw handle rectangle
    skRectangle(sketch1, "handle", {
        "firstCorner" : vector(-handleLength/2, -handleWidth/2),
        "secondCorner" : vector(handleLength/2 - headRadius, handleWidth/2)
    });
    
    // Draw head circle (open end)
    skCircle(sketch1, "head", {
        "center" : vector(handleLength/2 - headRadius/2, 0 * millimeter),
        "radius" : headRadius
    });
    
    skSolve(sketch1);
    
    // Extrude the sketch
    opExtrude(context, id + "extrude1", {
        "entities" : qSketchRegion(id + "sketch1"),
        "direction" : evOwnerSketchPlane(context, {"entity" : qSketchRegion(id + "sketch1")}).normal,
        "endBound" : BoundingType.BLIND,
        "endDepth" : thickness
    });
    
    return { "success" : true };
}
'''
    
    print("\n=== Attempt 1: Basic FeatureScript wrench ===")
    result = m.tool_onshape_eval_featurescript({"script": script})
    
    response = result.get("response", {})
    print(f"Response keys: {list(response.keys()) if isinstance(response, dict) else type(response)}")
    
    if isinstance(response, dict):
        if response.get("notices"):
            print("Notices:")
            for notice in response.get("notices", []):
                print(f"  - {notice.get('message', notice)}")
        if response.get("result"):
            print(f"Result: {response.get('result')}")
        if response.get("console"):
            print(f"Console: {response.get('console')}")
    
    return result


def attempt_wrench_featurescript_v2(m):
    """
    Attempt 2: Simpler approach - just create geometry directly with opExtrude
    using pre-built sketch regions.
    """
    
    script = '''
function(context is Context, queries is map)
{
    // Parameters
    var length = 6 * inch;
    var width = 0.75 * inch;
    var thickness = 0.25 * inch;
    var headSize = 1 * inch;
    
    // Create sketch on Top plane
    var sketch1 = newSketch(context, id + "sketch1", {
        "sketchPlane" : qCreatedBy(makeId("Top"), EntityType.FACE)
    });
    
    // Simple rectangle for handle
    skRectangle(sketch1, "rect1", {
        "firstCorner" : vector(0, -width/2),
        "secondCorner" : vector(length - headSize, width/2)
    });
    
    // Circle for head
    skCircle(sketch1, "circle1", {
        "center" : vector(length - headSize/2, 0 * inch),
        "radius" : headSize / 2
    });
    
    skSolve(sketch1);
    
    // Extrude
    extrude(context, id + "extrude1", {
        "entities" : qSketchRegion(id + "sketch1"),
        "endBound" : BoundingType.BLIND,
        "depth" : thickness
    });
    
    return { "created" : true };
}
'''
    
    print("\n=== Attempt 2: Using newSketch with qCreatedBy ===")
    result = m.tool_onshape_eval_featurescript({"script": script})
    
    response = result.get("response", {})
    if isinstance(response, dict):
        if response.get("notices"):
            print("Notices:")
            for notice in response.get("notices", []):
                msg = notice.get("message", str(notice))
                print(f"  - {msg[:200]}")
        if response.get("result"):
            print(f"Result: {response.get('result')}")
    
    return result


def attempt_wrench_native_features(m):
    """
    Attempt 3: Use native feature API calls instead of FeatureScript.
    Create sketch + extrude as separate features.
    """
    
    print("\n=== Attempt 3: Native feature API (sketch + extrude) ===")
    
    created_ids = []
    
    # Create a sketch with multiple entities (rectangle + circle)
    sketch_body = {
        "btType": "BTFeatureDefinitionCall-1406",
        "feature": {
            "btType": "BTMSketch-151",
            "featureType": "newSketch",
            "name": "Wrench Sketch",
            "parameters": [
                {
                    "btType": "BTMParameterQueryList-148",
                    "queries": [
                        {
                            "btType": "BTMIndividualQuery-138",
                            "queryString": 'query=qCreatedBy(makeId("Top"), EntityType.FACE);',
                        }
                    ],
                    "parameterId": "sketchPlane",
                }
            ],
            "entities": [
                # Rectangle for handle (as 4 lines)
                {
                    "btType": "BTMSketchCurveSegment-155",
                    "geometry": {
                        "btType": "BTCurveGeometryLine-117",
                        "pntX": 0,
                        "pntY": -0.01,  # -10mm
                        "dirX": 0.1,    # 100mm length
                        "dirY": 0,
                    },
                    "startParam": 0,
                    "endParam": 1,
                    "entityId": "line1",
                },
                {
                    "btType": "BTMSketchCurveSegment-155",
                    "geometry": {
                        "btType": "BTCurveGeometryLine-117",
                        "pntX": 0.1,
                        "pntY": -0.01,
                        "dirX": 0,
                        "dirY": 0.02,
                    },
                    "startParam": 0,
                    "endParam": 1,
                    "entityId": "line2",
                },
                {
                    "btType": "BTMSketchCurveSegment-155",
                    "geometry": {
                        "btType": "BTCurveGeometryLine-117",
                        "pntX": 0.1,
                        "pntY": 0.01,
                        "dirX": -0.1,
                        "dirY": 0,
                    },
                    "startParam": 0,
                    "endParam": 1,
                    "entityId": "line3",
                },
                {
                    "btType": "BTMSketchCurveSegment-155",
                    "geometry": {
                        "btType": "BTCurveGeometryLine-117",
                        "pntX": 0,
                        "pntY": 0.01,
                        "dirX": 0,
                        "dirY": -0.02,
                    },
                    "startParam": 0,
                    "endParam": 1,
                    "entityId": "line4",
                },
                # Circle for head
                {
                    "btType": "BTMSketchCurve-4",
                    "geometry": {
                        "btType": "BTCurveGeometryCircle-115",
                        "radius": 0.015,  # 15mm
                        "xCenter": 0.12,  # 120mm from origin
                        "yCenter": 0,
                        "xDir": 1,
                        "yDir": 0,
                        "clockwise": False,
                    },
                    "centerId": "circle1.center",
                    "entityId": "circle1",
                },
            ],
            "constraints": [],
        },
    }
    
    did = m.STATE.did
    wid = m.STATE.wvmid
    eid = m.STATE.eid
    
    sketch_result = m.CLIENT.add_partstudio_feature(did, "w", wid, eid, sketch_body)
    sketch_fid = _extract_feature_id(sketch_result)
    
    if sketch_fid:
        created_ids.append(sketch_fid)
        print(f"  Created sketch: {sketch_fid}")
    else:
        print(f"  Sketch creation failed: {sketch_result}")
        return {"created_ids": created_ids, "error": "Sketch failed"}
    
    # Now extrude
    extrude_body = {
        "btType": "BTFeatureDefinitionCall-1406",
        "feature": {
            "btType": "BTMFeature-134",
            "featureType": "extrude",
            "name": "Wrench Extrude",
            "parameters": [
                {
                    "btType": "BTMParameterEnum-145",
                    "value": "SOLID",
                    "enumName": "ExtendedToolBodyType",
                    "parameterId": "bodyType",
                },
                {
                    "btType": "BTMParameterEnum-145",
                    "value": "NEW",
                    "enumName": "NewBodyOperationType",
                    "parameterId": "operationType",
                },
                {
                    "btType": "BTMParameterQueryList-148",
                    "queries": [
                        {"btType": "BTMIndividualSketchRegionQuery-140", "featureId": sketch_fid}
                    ],
                    "parameterId": "entities",
                },
                {
                    "btType": "BTMParameterEnum-145",
                    "value": "BLIND",
                    "enumName": "BoundingType",
                    "parameterId": "endBound",
                },
                {
                    "btType": "BTMParameterQuantity-147",
                    "expression": "5 mm",
                    "parameterId": "depth"
                },
            ],
            "returnAfterSubfeatures": False,
            "suppressed": False,
        },
    }
    
    extrude_result = m.CLIENT.add_partstudio_feature(did, "w", wid, eid, extrude_body)
    extrude_fid = _extract_feature_id(extrude_result)
    
    if extrude_fid:
        created_ids.append(extrude_fid)
        print(f"  Created extrude: {extrude_fid}")
    else:
        print(f"  Extrude creation failed: {extrude_result}")
    
    return {"created_ids": created_ids, "sketch": sketch_result, "extrude": extrude_result}


def check_bounding_box(m):
    """Check bounding box to verify geometry was created."""
    result = m.tool_onshape_get_partstudio_bounding_boxes({})
    if isinstance(result, dict) and not result.get("error"):
        print(f"Bounding boxes: {json.dumps(result, indent=2)[:500]}")
    return result


def main():
    _ensure_env()
    ensure_onshape_agent_on_path()
    
    url = os.environ.get("ONSHAPE_TEST_URL", "").strip() or DEFAULT_TEST_URL
    
    # Import after env setup
    import onshape_mcp_server as m
    
    ctx = setup_context(m, url)
    
    # Get initial state
    initial_features = get_current_features(m)
    print(f"\nInitial features: {len(initial_features)}")
    for f in initial_features:
        print(f"  - {f.get('name')} ({f.get('featureType')}) [{f.get('featureId')}]")
    
    # Run attempts
    all_created_ids = []
    
    try:
        # Attempt 1: FeatureScript v1
        result1 = attempt_wrench_featurescript_v1(m)
        
        # Check what was created
        features_after_1 = get_current_features(m)
        new_features_1 = [f for f in features_after_1 if f not in initial_features]
        print(f"New features after attempt 1: {len(new_features_1)}")
        for f in new_features_1:
            print(f"  - {f.get('name')} ({f.get('featureType')})")
            if f.get('featureId'):
                all_created_ids.append(f.get('featureId'))
        
        # Attempt 2: FeatureScript v2
        result2 = attempt_wrench_featurescript_v2(m)
        
        features_after_2 = get_current_features(m)
        new_features_2 = [f for f in features_after_2 if f.get('featureId') not in [x.get('featureId') for x in features_after_1]]
        print(f"New features after attempt 2: {len(new_features_2)}")
        for f in new_features_2:
            print(f"  - {f.get('name')} ({f.get('featureType')})")
            if f.get('featureId'):
                all_created_ids.append(f.get('featureId'))
        
        # Attempt 3: Native features
        result3 = attempt_wrench_native_features(m)
        if result3.get("created_ids"):
            all_created_ids.extend(result3["created_ids"])
        
        # Check final bounding box
        print("\n=== Final state ===")
        check_bounding_box(m)
        
        final_features = get_current_features(m)
        print(f"Total features now: {len(final_features)}")
        
    finally:
        # Cleanup
        print(f"\n=== Cleanup: deleting {len(all_created_ids)} features ===")
        cleanup_features(m, all_created_ids)
    
    print("\nDone.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
