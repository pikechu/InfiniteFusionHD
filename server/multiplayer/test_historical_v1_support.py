"""Historical v1 fixtures, kept to verify archived receipts and old settlements.

Production always uses service.Store and closes new v1 gameplay. This test-only
subclass recreates the earlier service for historical engine regression cases.
"""
from service import Store


class HistoricalV1Store(Store):
    def controlled_v1_action_allowed(self, db, character_id, action):
        return True
