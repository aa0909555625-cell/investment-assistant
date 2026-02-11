from abc import ABC, abstractmethod
from typing import List, Optional
from src.domain.models import Decision


class Strategy(ABC):
    """
    所有策略的統一介面
    """

    @abstractmethod
    def decide(
        self,
        symbol: str,
        closes: List[float],
    ) -> Optional[Decision]:
        """
        回傳 Decision 或 None
        """
        raise NotImplementedError
