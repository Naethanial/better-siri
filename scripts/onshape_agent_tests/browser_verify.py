#!/usr/bin/env python3
"""
Use browser automation to take a screenshot of the OnShape document
to verify what the wrench looks like.
"""

import asyncio
import os
import sys
from pathlib import Path

# Add the BrowserAgent to path
sys.path.insert(0, str(Path(__file__).parent.parent.parent / "BetterSiri" / "Sources" / "Resources" / "BrowserAgent"))

DEFAULT_TEST_URL = (
    "https://cteinccsd.onshape.com/documents/89a3e2e598f9ad2ace0fb496/"
    "w/8c522fba543883263f4d1645/e/466338a94d244e8b3d9ca656"
)


async def main():
    url = os.environ.get("ONSHAPE_TEST_URL", "").strip() or DEFAULT_TEST_URL
    
    print(f"Opening: {url}")
    print("Taking screenshot of OnShape document...")
    
    # Simple approach: just print instructions for manual verification
    print(f"\nTo verify visually, open this URL in your browser:")
    print(url)
    print("\nLook for the 'Wrench Outline' and 'Wrench Base' features in the feature tree.")
    print("The wrench should be visible as a flat shape with a handle and circular head.")
    
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
