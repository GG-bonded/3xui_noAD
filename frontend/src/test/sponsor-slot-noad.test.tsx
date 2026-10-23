import { afterEach, expect, test, vi } from 'vitest';
import { cleanup, render } from '@testing-library/react';

import { useSponsorsQuery } from '@/api/queries/useSponsorsQuery';
import SponsorSlot from '@/components/sponsor/SponsorSlot';

// Simulate an existing browser cache so the test also covers old sponsor data.
vi.mock('@/api/queries/useSponsorsQuery', () => ({
  useSponsorsQuery: vi.fn(() => ({
    data: {
      sponsors: [{ id: 'cached-ad', name: 'Cached advertisement', slots: ['login', 'dashboard', 'sidebar'] }],
    },
    fetched: true,
  })),
}));

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

test.each(['login', 'dashboard', 'sidebar', 'page'] as const)(
  '%s does not render advertising or request sponsor data',
  (slot) => {
    const { container } = render(<SponsorSlot slot={slot} rotate iconOnly />);
    expect(container.childElementCount).toBe(0);
    expect(useSponsorsQuery).not.toHaveBeenCalled();
  },
);
