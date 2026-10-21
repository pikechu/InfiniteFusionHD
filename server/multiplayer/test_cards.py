"""Trainer cards expose only voluntary, currently owned public projections."""
import copy
import unittest

import test_v3 as fixtures
from test_service import pokemon


class CardsTests(unittest.TestCase):
    setUp = fixtures.V3Tests.setUp
    tearDown = fixtures.V3Tests.tearDown
    identity = fixtures.V3Tests.identity
    call = fixtures.V3Tests.call
    restart = fixtures.V3Tests.restart
    starter = fixtures.V3Tests.starter
    hosted_deposit = fixtures.V3Tests.hosted_deposit

    def showcase(self, person=None, fields=None):
        return self.call(person or self.alice, "POST", "/v1/showcases", {"snapshot": pokemon(), "public_fields": fields or []})["showcase"]

    def update(self, person=None, **extra):
        return self.call(person or self.alice, "POST", "/v1/cards/me", {"avatar": "POKEMONTRAINER_Red", "show_badges": False, "showcases": [], **extra})["card"]

    def test_default_card_friend_lookup_and_no_private_credentials(self):
        own = self.call(self.alice, "GET", "/v1/cards/me")["card"]
        public = self.call(self.bob, "GET", "/v1/cards/" + self.alice["identity"]["friend_code"].lower())["card"]
        self.assertEqual(own, public)
        self.assertEqual(own["avatar"], "POKEMONTRAINER_Red")
        self.assertEqual(own["capacity"], 6)
        self.assertEqual(own["badges"], [])
        self.assertFalse(own["show_badges"])
        self.assertEqual(set(own), {"id", "nickname", "friend_code", "avatar", "show_badges", "badges", "showcases", "showcase_codes", "capacity"})
        self.call(self.bob, "GET", "/v1/cards/00000000", expected=404)
        self.call(self.bob, "GET", "/v1/cards/../private", expected=404)

    def test_avatar_trusted_registry_path_rejection_and_foreign_write(self):
        self.update(avatar="POKEMONTRAINER_Leaf")
        for avatar, status in (("../../Graphics/secret.png", 400), ("NOT_A_REAL_TRAINER_TYPE", 409), (True, 400)):
            self.call(self.alice, "POST", "/v1/cards/me", {"avatar": avatar, "show_badges": False, "showcases": []}, status)
        self.call(self.bob, "POST", "/v1/cards/" + self.alice["identity"]["friend_code"], {"avatar": "POKEMONTRAINER_Red", "show_badges": False, "showcases": []}, 404)
        self.assertEqual(self.call(self.alice, "GET", "/v1/cards/me")["card"]["avatar"], "POKEMONTRAINER_Leaf")

    def test_badges_require_opt_in_and_only_own_actual_medals(self):
        alice_id, bob_id = self.alice["identity"]["id"], self.bob["identity"]["id"]
        with self.store.connect() as db:
            for index, kind in enumerate(("boss_medal", "gym_medal", "dungeon_medal", "hosted_starter_grant")):
                self.store.claim_reward(db, alice_id, "card_fixture:" + str(index), {"kind": kind, "boss_id": "boss", "asset_id": "private_asset", "battle_id": "private_battle", "secret": "hidden"})
            self.store.claim_reward(db, bob_id, "card_fixture", {"kind": "boss_medal", "boss_id": "bob_only"})
        self.assertEqual(self.call(self.bob, "GET", "/v1/cards/" + self.alice["identity"]["friend_code"])["card"]["badges"], [])
        public = self.update(show_badges=True)
        self.assertEqual(len(public["badges"]), 3)
        self.assertTrue(all(set(badge) <= {"id", "kind", "boss_id", "gym_code", "dungeon_id"} and badge["boss_id"] != "bob_only" for badge in public["badges"]))
        self.assertEqual(self.update()["badges"], [])
        self.call(self.alice, "POST", "/v1/cards/me", {"avatar": "POKEMONTRAINER_Red", "show_badges": True, "showcases": [], "badges": [{"kind": "forged"}]}, 400)

    def test_six_showcase_slots_order_duplicate_and_inactive_rejected(self):
        showcases = [self.showcase() for _ in range(7)]
        codes = [showcase["code"] for showcase in showcases]
        self.call(self.alice, "POST", "/v1/cards/me", {"avatar": "POKEMONTRAINER_Red", "show_badges": False, "showcases": codes}, 400)
        selected = list(reversed(codes[:6]))
        card = self.update(showcases=selected)
        self.assertEqual(card["showcase_codes"], selected)
        self.assertEqual(len(card["showcases"]), 6)
        self.call(self.alice, "POST", "/v1/cards/me", {"avatar": "POKEMONTRAINER_Red", "show_badges": False, "showcases": [codes[0], codes[0].lower()]}, 400)
        self.call(self.alice, "POST", "/v1/showcases/" + codes[0] + "/unpublish", {})
        current = self.call(self.bob, "GET", "/v1/cards/" + self.alice["identity"]["friend_code"])["card"]
        self.assertEqual(len(current["showcases"]), 5)
        self.call(self.alice, "POST", "/v1/cards/me", {"avatar": "POKEMONTRAINER_Red", "show_badges": False, "showcases": [codes[0]]}, 403)

    def test_showcase_permissions_public_fields_and_cross_device_owned_list(self):
        own, other = self.showcase(), self.showcase(self.bob, ["name", "iv"])
        self.call(self.alice, "POST", "/v1/cards/me", {"avatar": "POKEMONTRAINER_Red", "show_badges": False, "showcases": [other["code"]]}, 403)
        card = self.update(showcases=[own["code"].lower()])
        public = card["showcases"][0]["snapshot"]
        self.assertNotIn("iv", public)
        self.assertNotIn("ev", public)
        self.assertNotIn("owner", public)
        self.assertNotIn("head_nickname", public["appearance"])
        self.assertNotIn("personal_id", public)
        owned = self.call(self.alice, "GET", "/v1/showcases")["showcases"]
        self.assertEqual([item["code"] for item in owned], [own["code"]])
        self.restart()
        restored = self.call(self.alice, "GET", "/v1/cards/me")["card"]
        self.assertEqual(restored, card)
        self.assertEqual(self.call(self.alice, "GET", "/v1/showcases")["showcases"], owned)

    def test_edited_showcase_card_tracks_current_projection(self):
        own = self.showcase()
        self.update(showcases=[own["code"]])
        snapshot = pokemon()
        snapshot["name"] = "公开昵称"
        changed = self.call(self.alice, "POST", "/v1/showcases", {"code": own["code"], "snapshot": snapshot, "public_fields": ["name", "owner"]})["showcase"]
        card = self.call(self.bob, "GET", "/v1/cards/" + self.alice["identity"]["friend_code"])["card"]
        self.assertEqual(card["showcases"], [changed])

    def test_hosted_ownership_transfer_dynamically_hides_old_card_slot(self):
        a, b = self.starter(self.alice), self.starter(self.bob)
        showcase = self.call(self.alice, "POST", "/v1/collections/" + a["id"] + "/showcase", {})["showcase"]
        self.update(showcases=[showcase["code"]])
        self.call(self.alice, "POST", "/v1/showcases", {"code": showcase["code"], "snapshot": pokemon("MEW"), "public_fields": []}, 409)
        self.assertEqual(self.call(self.alice, "GET", "/v1/showcases/" + showcase["code"])["showcase"]["source"], "server_managed")
        self.hosted_deposit(self.alice, a)
        self.hosted_deposit(self.bob, b)
        self.assertEqual(self.call(self.alice, "GET", "/v1/cards/me")["card"]["showcases"], [])
        # Even an old active cache flag cannot override current server ownership.
        with self.store.connect() as db:
            db.execute("UPDATE showcases SET active=1 WHERE code=?", (showcase["code"],))
        self.assertEqual(self.call(self.alice, "GET", "/v1/showcases")["showcases"], [])
        self.assertEqual(self.call(self.bob, "GET", "/v1/cards/" + self.alice["identity"]["friend_code"])["card"]["showcases"], [])

    def test_update_idempotence_and_request_id_conflict(self):
        first = self.update(request_id="same_card_update", show_badges=True)
        second = self.update(request_id="same_card_update", show_badges=True)
        self.assertEqual(first, second)
        self.call(self.alice, "POST", "/v1/cards/me", {"avatar": "POKEMONTRAINER_Red", "show_badges": False, "showcases": [], "request_id": "same_card_update"}, 409)


if __name__ == "__main__":
    unittest.main()
