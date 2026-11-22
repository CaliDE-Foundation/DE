//! The calendar under the clock: month grids, week starting on Sunday.

/// One cell of the month grid.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CaliDay {
    pub day: u8,
    /// False for the trailing days of the previous month and leading days
    /// of the next one, which fill out the grid.
    pub in_month: bool,
    pub today: bool,
}

pub const CELLS: usize = 42; // 6 weeks x 7 days

pub fn is_leap(year: i32) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

/// `month` is 1-12.
pub fn days_in_month(year: i32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap(year) => 29,
        _ => 28,
    }
}

/// Day of the week, 0 = Sunday (Sakamoto's method).
pub fn weekday(year: i32, month: u32, day: u32) -> u32 {
    const T: [i32; 12] = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
    let y = if month < 3 { year - 1 } else { year };
    (y + y.div_euclid(4) - y.div_euclid(100) + y.div_euclid(400) + T[month as usize - 1] + day as i32)
        .rem_euclid(7) as u32
}

/// Moves `delta` months from `year`/`month`.
pub fn add_months(year: i32, month: u32, delta: i32) -> (i32, u32) {
    let index = year * 12 + month as i32 - 1 + delta;
    (index.div_euclid(12), index.rem_euclid(12) as u32 + 1)
}

/// The 6x7 grid for `year`/`month`, marking `today` (year, month, day) if
/// it falls in it.
pub fn grid(year: i32, month: u32, today: (i32, u32, u32)) -> [CaliDay; CELLS] {
    let mut cells = [CaliDay::default(); CELLS];
    let lead = weekday(year, month, 1) as usize;
    let (py, pm) = add_months(year, month, -1);
    let prev_days = days_in_month(py, pm);
    let days = days_in_month(year, month);
    let (ny, nm) = add_months(year, month, 1);

    for (i, cell) in cells.iter_mut().enumerate() {
        let (y, m, d, in_month) = if i < lead {
            (py, pm, prev_days - (lead - i) as u32 + 1, false)
        } else if i - lead < days as usize {
            (year, month, (i - lead) as u32 + 1, true)
        } else {
            (ny, nm, (i - lead) as u32 - days + 1, false)
        };
        *cell = CaliDay { day: d as u8, in_month, today: (y, m, d) == today };
    }
    cells
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn weekdays() {
        assert_eq!(weekday(2026, 11, 22), 0); // a Sunday
        assert_eq!(weekday(2000, 1, 1), 6); // a Saturday
        assert_eq!(weekday(2024, 2, 29), 4); // a Thursday
    }

    #[test]
    fn month_lengths_and_leap_years() {
        assert_eq!(days_in_month(2024, 2), 29);
        assert_eq!(days_in_month(2100, 2), 28);
        assert_eq!(days_in_month(2000, 2), 29);
        assert_eq!(days_in_month(2026, 11), 30);
    }

    #[test]
    fn month_arithmetic_wraps_years() {
        assert_eq!(add_months(2026, 1, -1), (2025, 12));
        assert_eq!(add_months(2026, 12, 1), (2027, 1));
        assert_eq!(add_months(2026, 11, -23), (2024, 12));
    }

    #[test]
    fn november_2026_grid() {
        let g = grid(2026, 11, (2026, 11, 22));
        // Nov 1 2026 is a Sunday, so the grid starts on it.
        assert_eq!(g[0], CaliDay { day: 1, in_month: true, today: false });
        assert_eq!(g[21], CaliDay { day: 22, in_month: true, today: true });
        assert_eq!(g[29], CaliDay { day: 30, in_month: true, today: false });
        assert_eq!(g[30], CaliDay { day: 1, in_month: false, today: false });
        assert_eq!(g.iter().filter(|d| d.today).count(), 1);
    }

    #[test]
    fn leading_days_come_from_the_previous_month() {
        let g = grid(2026, 12, (2000, 1, 1)); // Dec 1 2026 is a Tuesday
        assert_eq!(g[0], CaliDay { day: 29, in_month: false, today: false });
        assert_eq!(g[1].day, 30);
        assert_eq!(g[2], CaliDay { day: 1, in_month: true, today: false });
    }
}
