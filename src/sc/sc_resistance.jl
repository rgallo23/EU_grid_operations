function sc_eq_res(length, dc_voltage, cooling_power)
    
    r = (length*cooling_power)/(dc_voltage^2) # length in km , cooling power in MW/km , and dc_voltage in kV

    return r
end