import type { SponsorSlot as Slot } from '@/lib/sponsors';
import type { SponsorCardVariant } from './SponsorCard';

interface SponsorSlotProps {
  slot: Slot;
  variant?: SponsorCardVariant;
  iconOnly?: boolean;
  rotate?: boolean;
  className?: string;
}

export default function SponsorSlot(_props: SponsorSlotProps) {
  // NoAD: never render a paid placement or read previously cached advertising.
  return null;
}
