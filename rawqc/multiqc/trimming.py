#!/ust/bin/env python3
# coding: utf-8

""" MultiQC module to parse JSON file generated by `rawqc_atropos`.
"""

import json
from collections import OrderedDict

from multiqc.modules.base_module import BaseMultiqcModule
from multiqc.plots import table, linegraph


class MultiqcModule(BaseMultiqcModule):
    """ Trimming module with rawqc_atropos.
    """
    def __init__(self):
        # Init the parent object
        super(MultiqcModule, self).__init__(
            name="Trimming",
            anchor="trimming",
            href="https://atropos.readthedocs.io/en/latest/",
            info="using Atropos, it detects and trims adapters from a list of"
                 " a list of adapters."
        )

        self.trimming_data = dict()
        for f in self.find_log_files("rawqc_trimming", filehandles=True):
            self.parse_rawqc_trim_log(f)

        if len(self.metrics_data) == 0:
            raise UserWarning

        self.add_section(plot=self.adapter_used_table())

    def parse_rawqc_trim_log(self, f):
        """ Parse the json file.
        """
        data = json.load(f['f'])
        self.trimming_data[data['id']] = data

    def adapter_used_table(self):
        """ Create a table with adapters used for each sample.
        """
        headers = OrderedDict()
        headers['-a'] = {
            "namespace": "Trimming",
            "title": "Read 1 3'",
            "description": "Sequence removed at 3' of read 1",
            "format": None,
            "scale": None,
        }
        headers['-g'] = {
            "namespace": "Trimming",
            "title": "Read 1 5'",
            "description": "Sequence removed at 5' of read 1",
            "format": None,
            "scale": None,
        }
        headers['-b'] = {
            "namespace": "Trimming",
            "title": "Read 1 both",
            "description": "Sequence removed at both side of read 1",
            "format": None,
            "scale": None,
        }
        headers['-A'] = {
            "namespace": "Trimming",
            "title": "Read 2 3'",
            "description": "Sequence removed at 3' of read 2",
            "format": None,
            "scale": None,
        }
        headers['-G'] = {
            "namespace": "Trimming",
            "title": "Read 2 5'",
            "description": "Sequence removed at 5' of read 2",
            "format": None,
            "scale": None,
        }
        headers['-B'] = {
            "namespace": "Trimming",
            "title": "Read 2 both",
            "description": "Sequence removed at both side of read 2",
            "format": None,
            "scale": None,
        }
        config = {
            'id': 'rawqc_used_adapters',
            'table_title': 'Adapters removed',
            'save_file': True
        }
        return table.plot(self.trimming_data, headers, config)

    def trimming_length_plot(self):
        """ Generate the trimming length plot.
        """
        description = (
          "This plot shows the number of reads with certain lengths of adapter"
          " trimmed. Obs/Exp shows the raw counts divided by the number"
          " expected due to sequencing errors. A defined peak may be related"
          " to adapter length."  
        )
