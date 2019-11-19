import json
import unittest
import uuid
from datetime import datetime
from datetime import timedelta
from datetime import timezone
from unittest import main
from unittest import TestCase
from unittest.mock import Mock
from unittest.mock import patch

import marshmallow

from app import create_app
from app.exceptions import InventoryException
from app.queue.ingress import event_loop
from app.queue.ingress import handle_message
from lib.host_repository import AddHostResults


class FakeKafkaMessage:
    value = None

    def __init__(self, message):
        self.value = message


class mockEventProducer:
    def __init__(self):
        self.__data = {}

    def write_event(self, val):
        self.__data["write_event"] = val

    def get_write_event(self):
        return self.__data["write_event"]


class MQServiceTestCase(TestCase):
    def setUp(self):
        """
        Creates the application and a test client to make requests.
        """
        self.app = create_app(config_name="testing")

    def test_event_loop_exception_handling(self):
        """
        Test to ensure that an exception in message handler method does not cause the
        event loop to stop processing messages
        """
        # fake_consumer = [FakeKafkaMessage("blah"), FakeKafkaMessage("fred"), FakeKafkaMessage("ugh")]
        fake_consumer = [Mock(), Mock(), Mock()]
        fake_event_producer = None

        handle_message_mock = Mock(side_effect=[None, KeyError("blah"), None])
        event_loop(fake_consumer, self.app, fake_event_producer, handler=handle_message_mock)

        self.assertEqual(handle_message_mock.call_count, 3)

    def test_handle_message_failure_invalid_json_message(self):

        invalid_message = "failure {} "
        mock_event_producer = Mock()

        with self.assertRaises(json.decoder.JSONDecodeError):
            handle_message(invalid_message, mock_event_producer)

        mock_event_producer.assert_not_called()

    def test_handle_message_failure_invalid_message_format(self):

        invalid_message = json.dumps({"operation": "add_host", "NOTdata": {}})  # Missing data field

        mock_event_producer = Mock()

        with self.assertRaises(marshmallow.exceptions.ValidationError):
            handle_message(invalid_message, mock_event_producer)

        mock_event_producer.assert_not_called()

    @patch("app.queue.egress.datetime", **{"utcnow.return_value": datetime.utcnow()})
    def test_handle_message_happy_path(self, datetime_mock):
        expected_insights_id = str(uuid.uuid4())
        host_id = uuid.uuid4()
        timestamp_iso = datetime_mock.utcnow.return_value.isoformat() + "+00:00"
        message = {"operation": "add_host", "data": {"insights_id": expected_insights_id, "account": "0000001"}}
        with unittest.mock.patch("app.queue.ingress.host_repository.add_host") as m:
            m.return_value = ({"id": host_id, "insights_id": None}, AddHostResults.created)
            mock_event_producer = Mock()
            handle_message(json.dumps(message), mock_event_producer)

            mock_event_producer.write_event.assert_called_once()

            self.assertEquals(
                json.loads(mock_event_producer.write_event.call_args[0][0]),
                {
                    "host": {"id": str(host_id), "insights_id": None},
                    "platform_metadata": {},
                    "timestamp": timestamp_iso,
                    "type": "created",
                },
            )

    def test_handle_message_verify_threadctx_request_id_set_and_cleared(self):
        # set the threadctx.request_id
        # and clear it
        pass

    def test_handle_message_verify_metadata_pass_through(self):
        pass

    def test_handle_message_verify_metadata_is_not_required(self):
        pass


class MQAddHostTestCase(MQServiceTestCase):
    def setUp(self):
        super().setUp()

    def _base_add_host_test(self, host_data, expected_results, host_id, host_keys_to_check):
        message = {"operation": "add_host", "data": host_data}

        mock_event_producer = mockEventProducer()
        with self.app.app_context():
            handle_message(json.dumps(message), mock_event_producer)

        for key in host_keys_to_check:
            self.assertEqual(
                json.loads(mock_event_producer.get_write_event())["host"][key], expected_results["host"][key]
            )

    @patch("app.queue.egress.datetime", **{"utcnow.return_value": datetime.utcnow()})
    def test_add_host_stale_timestamp(self, datetime_mock):
        """
        Tests to see if the host is succesfully created with both reporter
        and stale_timestamp set.
        """
        expected_insights_id = str(uuid.uuid4())
        host_id = uuid.uuid4()
        timestamp_iso = datetime_mock.utcnow.return_value.isoformat() + "+00:00"
        stale_timestamp = datetime.now(timezone.utc)

        host_data = {
            "id": str(host_id),
            "display_name": "test_host",
            "insights_id": expected_insights_id,
            "account": "0000001",
            "stale_timestamp": stale_timestamp.isoformat(),
            "reporter": "puptoo",
        }

        expected_results = {
            "host": {
                **host_data,
                "stale_warning_timestamp": (stale_timestamp + timedelta(weeks=1)).isoformat(),
                "culled_timestamp": (stale_timestamp + timedelta(weeks=2)).isoformat(),
            },
            "platform_metadata": {},
            "timestamp": timestamp_iso,
            "type": "created",
        }

        host_keys_to_check = ["reporter", "stale_timestamp", "culled_timestamp"]

        self._base_add_host_test(host_data, expected_results, host_id, host_keys_to_check)

    def _base_incomplete_staleness_data_test(self, additional_host_data):
        expected_insights_id = str(uuid.uuid4())
        host_id = uuid.uuid4()

        host_data = {
            "id": str(host_id),
            "display_name": "test_host",
            "insights_id": expected_insights_id,
            "account": "0000001",
            **additional_host_data,
        }

        message = {"operation": "add_host", "data": host_data}
        mock_event_producer = mockEventProducer()

        with self.app.app_context():
            with self.assertRaises(InventoryException):
                handle_message(json.dumps(message), mock_event_producer)

    def test_add_host_stale_timestamp_no_reporter(self):
        """
        tests to check the API will reject a host if it has a stale_timestamp
        without a reporter. This shoul raise an inventory exception
        """

        stale_timestamp = datetime.now(timezone.utc)

        additional_host_data = {"stale_timestamp": stale_timestamp.isoformat()}

        self._base_incomplete_staleness_data_test(additional_host_data)

    def test_add_host_reporter_no_stale_timestamp(self):
        """
        tests to check the API will reject a host if it has a stale_timestamp
        without a reporter. This shoul raise an inventory exception
        """

        additional_host_data = {"reporter": "puptoo"}

        self._base_incomplete_staleness_data_test(additional_host_data)


if __name__ == "__main__":
    main()
