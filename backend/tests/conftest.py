import pytest

from nexa_insight_api.repositories import Repository


@pytest.fixture
def repo() -> Repository:
    repository = Repository("sqlite://")
    repository.create_schema()
    return repository
