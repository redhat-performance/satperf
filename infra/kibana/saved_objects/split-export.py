#!/usr/bin/env python3

"""
This tool is supposed to help with splitting saved objects export
ndjson file to individual files, so it is easier to manage in git.

To get the export from Elastic Search:

    Kibana -> Stack Management -> Saved Objects -> fileter for objects you are interested in -> Export X objects

To split it:

    $ ./split-export.py export.ndjson
    $ rm export.ndjson
    $ git add *.json
    $ git commit -m "New version of Kibana saved objects"
"""

import sys
import json


export_file = sys.argv[1]

print(f"Loading {export_file}")
with open(export_file, 'r') as export_fp:
    for row in export_fp:
        entity = json.loads(row)
        if 'exportedCount' in entity:
            pass   # this is just summary of the export like '{"exportedCount": 41, "missingRefCount": 0, "missingReferences": []}'
        elif 'type' in entity and 'id' in entity:
            output_file = f"{entity['type']}_{entity['id']}.json"
            print(f"Writing {output_file}")
            with open(output_file, 'w') as output_fp:
                json.dump([entity], output_fp, sort_keys=True, indent=4, separators=(',', ': '))
        else:
            raise Exception(f"Unknown document: {entity}")
