#!/usr/bin/env python3

"""
This tool is supposed to help with splitting saved objects export
json file to individual files, so it is easier to manage in git.

To get the export from Elastic Search:

    Kibana -> Management -> Saved Objects -> Export X objects

To split it:

    $ ./split-export.py export.json
    $ rm export.json
    $ git add *.json
    $ git commit -m "New version of Kibana saved objects"
"""

import sys
import json


export_file = sys.argv[1]

print(f"Loading {export_file}")
with open(export_file, 'r') as export_fp:
    print(f"Parsing {export_file}")
    export_data = json.load(export_fp)
    for entity in export_data:
        output_file = f"{entity['_type']}_{entity['_id']}.json"
        print(f"Writing {output_file}")
        with open(output_file, 'w') as output_fp:
            print(f"Dumping {output_file}")
            json.dump([entity], output_fp, sort_keys=True, indent=4, separators=(',', ': '))
